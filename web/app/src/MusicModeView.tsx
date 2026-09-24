import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { Device, RGB } from './bridge'
import { MUSIC_HELP, PRESET_COPY, ROLE_COPY, SOURCE_COPY, configurationFor } from './music/config'
import { GROOVES } from './music/grooves'
import { hsvToRgb } from './music/fixtures'
import { WebMusicSession, LatestMusicFrameSender, setFixtureRole, type MusicFrameCommand } from './music/session'
import { AURORA_PALETTE, SUNSET_PALETTE, OCEAN_PALETTE, CLUB_PALETTE, type FixtureRole, type MusicModePreset, type MusicModeConfiguration } from './music/types'

const PRESETS: Exclude<MusicModePreset, 'custom'>[] = [
  'ambient',
  'balanced',
  'concert',
  'cinematic',
  'soundcheck',
  'club',
  'halftime',
  'waltz',
]

const ROLES: FixtureRole[] = ['auto', 'wash', 'hit', 'accent', 'motion', 'off']

export function MusicModeView({
  devices,
  port,
  postFrame,
  onRunningChange,
}: {
  devices: Device[]
  onRunningChange?: (running: boolean) => void
  port: number
  postFrame: (
    port: number,
    states: MusicFrameCommand[],
  ) => Promise<unknown>
}) {
  const sessionRef = useRef<WebMusicSession | null>(null)
  if (!sessionRef.current) sessionRef.current = new WebMusicSession()
  const session = sessionRef.current
  const version = useSyncExternalStore(
    listener => session.subscribe(listener),
    () => session.version,
    () => session.version,
  )
  const state = session.state
  const [reduceMotion, setReduceMotion] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  useEffect(() => {
    const query = window.matchMedia('(prefers-reduced-motion: reduce)')
    const update = () => setReduceMotion(query.matches)
    query.addEventListener('change', update)
    return () => query.removeEventListener('change', update)
  }, [])
  const configure = (configuration: MusicModeConfiguration) => session.patch({
    configuration: reduceMotion ? { ...configuration, allowsFlashes: false, movementAmount: Math.min(.2, configuration.movementAmount) } : configuration,
  })
  useEffect(() => { if (reduceMotion) configure(state.configuration) }, [reduceMotion])
  const adjust = (key: 'masterBrightness' | 'effectIntensity' | 'beatSensitivity' | 'movementAmount' | 'movementSpeed' | 'colorChangeIntensity', value: number) =>
    configure({ ...state.configuration, [key]: value, preset: 'custom' })
  const orderedFixtures = [...state.fixtures].sort((a, b) => {
    const index = (id: string) => { const i = state.topology.fixtureOrder.indexOf(id); return i < 0 ? Number.MAX_SAFE_INTEGER : i }
    return index(a.id) - index(b.id)
  })
  const moveFixture = (id: string, offset: number) => {
    const ids = orderedFixtures.map(f => f.id)
    const from = ids.indexOf(id), to = from + offset
    if (from < 0 || to < 0 || to >= ids.length) return
    ;[ids[from], ids[to]] = [ids[to], ids[from]]
    session.patch({ topology: { ...state.topology, fixtureOrder: ids } })
  }
  useEffect(() => { onRunningChange?.(state.running); return () => onRunningChange?.(false) }, [state.running, onRunningChange])
  void version
  const [file, setFile] = useState<File | null>(null)
  const reachable = devices.filter(d => d.reachable)

  // Restore color and independent brightness only while this session still
  // owns the fixture. The bridge rejects restoration after a newer manual edit.
  const baseline = useRef<MusicFrameCommand[] | null>(null)
  const senderRef = useRef<LatestMusicFrameSender | null>(null)
  const postRef = useRef(postFrame); postRef.current=postFrame
  const portRef = useRef(port); portRef.current=port
  const owner = useRef(crypto.randomUUID())
  if (!senderRef.current) senderRef.current = new LatestMusicFrameSender(states=>postRef.current(portRef.current,states.map(state=>({
    ...state,owner:owner.current,controlRevision:baseline.current?.find(b=>b.fixtureID===state.fixtureID)?.controlRevision
  }))))
  const sender=senderRef.current
  const transition = useRef(Promise.resolve())
  const transitionEpoch = useRef(0)

  const start = (source: Parameters<WebMusicSession['start']>[0], audio?: File) => {
    const epoch=++transitionEpoch.current
    transition.current=transition.current.then(async()=>{
    if(epoch!==transitionEpoch.current) return
    await sender.stop()
    if(epoch!==transitionEpoch.current) return
    // Capture only when nothing is running: a Restart must not adopt a colour
    // the show itself painted as the state to go back to.
    if (!state.running) {
      baseline.current = reachable
        .filter((d): d is Device & { color: RGB } => Boolean(d.color) && session.state.fixtures.find(f=>f.id===d.id)?.role !== 'off')
        .map(d => ({ fixtureID: d.id, rgb: d.color, brightness:d.brightness/100,restoring:true,owner:owner.current,controlRevision:d.controlRevision ?? 0 }))
    }
    await session.start(source, audio)
    if (session.state.running && epoch===transitionEpoch.current) sender.start()
    })
    return transition.current
  }

  const stop = () => {
    ++transitionEpoch.current
    const previous=baseline.current; baseline.current=null
    const restore=state.configuration.restorePreviousState
    // Invalidate permission/capture work synchronously; serialize network restore
    // before any subsequent start. No old HTTP frame can follow the restore.
    const captureStopped=session.stop()
    transition.current=(async()=>{
      await captureStopped
      await sender.stop()
      if(previous?.length) await postFrame(port,restore?previous:previous.map(s=>({...s,restoring:false,release:true}))).catch(()=>undefined)
    })()
    return transition.current
  }

  // Leaving the tab or navigating away is a stop too, so the lights are not
  // abandoned mid-show.
  const stopRef = useRef(stop)
  stopRef.current = stop
  useEffect(() => () => { void stopRef.current() }, [])

  useEffect(() => {
    session.setDevices(reachable.map(d => ({ id: d.id, name: d.name, brand: d.brand, reachable: d.reachable })))
  }, [session, reachable.map(d => d.id).join('|')])

  useEffect(() => {
    session.setOnFrame(frame => sender.enqueue(frame))
    return () => session.setOnFrame(null)
  }, [session, sender])

  const snapshot = state.snapshot
  const presetCopyKey = state.configuration.preset === 'custom' ? 'balanced' : state.configuration.preset
  const tempo =
    snapshot.isTempoLocked && snapshot.tempo > 0 && snapshot.beatConfidence >= .4
      ? `${Math.round(snapshot.feltTempo || snapshot.tempo)} · ${snapshot.metre}/${snapshot.metre === 6 ? 8 : 4}`
      : 'Beat'

  return (
    <section className="music-desk">
      <div className="panel music-transport">
        <p className="eyebrow">Music Mode</p>
        <h2>{state.running ? 'Music is controlling this room' : 'Ready for music'}</h2>
        <details><summary>Sources, getting started, and flash limits</summary>
          <p>Audio is analyzed locally in this tab. Only lighting commands go to your bridge.</p>
          <ol className="steps">{MUSIC_HELP.steps.map(step => <li key={step}>{step}</li>)}</ol>
          <p>{MUSIC_HELP.safety}</p>
        </details>
        <p className="note">{reduceMotion ? "Reduced Motion: flashes blocked; movement limited." : state.configuration.photosensitivitySafeMode ? "No-flash mode: explicit flashes blocked." : "Controlled flashes enabled."} Brightness changes can still be uncomfortable. Stop restores the captured output.</p>
        <div className="music-toolbar">
          <button
            className="primary"
            disabled={!reachable.length && state.source !== 'demo'}
            onClick={() => void start(state.source === 'file' && file ? 'file' : state.source === 'midi' ? 'midi' : state.source === 'microphone' ? 'microphone' : 'demo', file ?? undefined)}
          >
            {state.running ? 'Restart' : 'Start'}
          </button>
          <button onClick={() => void stop()} disabled={!state.running}>
            Stop
          </button>
          <button
            onClick={() => void start('demo')}
            className={state.source === 'demo' ? 'nav active' : undefined}
            title={SOURCE_COPY.demo.plain}
          >
            Demo groove
          </button>
          <button
            onClick={() => void start('microphone')}
            className={state.source === 'microphone' ? 'nav active' : undefined}
            title={SOURCE_COPY.microphone.plain}
          >
            Microphone
          </button>
          <label className="file-key" title={SOURCE_COPY.file.plain}>
            Open audio file
            <input
              type="file"
              accept="audio/*"
              onChange={event => {
                const next = event.target.files?.[0]
                if (!next) return
                setFile(next)
                void start('file', next)
              }}
            />
          </label>
          <button onClick={() => void start('midi')} title={SOURCE_COPY.midi.plain}>
            MIDI clock
          </button>
        </div>
        <p className="note">{SOURCE_COPY[state.source]?.plain ?? SOURCE_COPY.demo.plain}</p>
        {state.error && (
          <p className="error" role="alert">
            {state.error}
          </p>
        )}
        <p className="meta">
          {state.running ? 'Running' : 'Idle'} · {sourceLabel(state.source, state.fileName)} · {reachable.length} lights
          {state.midiClock ? ' · MIDI' : ''}
        </p>
      </div>

      <div className="panel">
        <p className="eyebrow">Preset</p>
        <div className="chip-row">
          {PRESETS.map(id => (
            <button
              key={id}
              className={state.configuration.preset === id ? 'chip on' : 'chip'}
              aria-pressed={state.configuration.preset === id}
              onClick={() => configure(configurationFor(id))}
            >
              {PRESET_COPY[id].name}
            </button>
          ))}
        </div>
        <p>{state.configuration.preset === 'custom' ? 'Custom balance. Choosing a preset replaces these adjustments.' : PRESET_COPY[presetCopyKey].plain}</p>
        {state.source === 'demo' && (
          <label className="field">
            Demo groove
            <select
              value={state.grooveId}
              onChange={event => session.patch({ grooveId: event.target.value })}
            >
              {GROOVES.map(groove => (
                <option key={groove.id} value={groove.id}>
                  {groove.name} — {groove.summary}
                </option>
              ))}
            </select>
          </label>
        )}
      </div>

      <div className="music-performance">
        <div className="music-output">
      <div className="panel meters">
        <Meter label="Input" value={snapshot.level} />
        <Meter label="Energy" value={snapshot.energy} />
        <div className="beat-readout">

          <strong>{!state.running ? 'Stopped' : tempo === 'Beat' ? 'Finding a pulse' : tempo}</strong>
          <span>{state.source === 'midi' ? 'Measured MIDI clock · ' : ''}Confidence {Math.round(snapshot.beatConfidence * 100)}%</span>
        </div>
        <p className="note">Audio input and musical interpretation. Generated colors below are not device confirmations.</p>
        <details><summary>Audio diagnostics</summary><Meter label="Bass" value={snapshot.bass}/><Meter label="Mids" value={snapshot.mids}/><Meter label="Highs" value={snapshot.highs}/></details>
      </div>

      <div className="panel">
        <p className="eyebrow">Which light does what</p>
        <p className="note">Generated output in fixture order. Assign roles and move fixtures with the arrow buttons.</p>
        {state.fixtures.length === 0 ? (
          <p>No lights yet. Use Find lights in Room, or run a demo groove to watch the lights move without any hardware.</p>
        ) : (
          <ul className="fixture-list">
            {orderedFixtures.map((fixture, index) => {
              const stateFor = state.frame?.states.find(s => s.fixtureID === fixture.id)
              const rgb = stateFor ? hsvToRgb(stateFor.hue, stateFor.saturation, stateFor.brightness) : null
              return (
                <li key={fixture.id}>
                  <span
                    className="fixture-swatch"
                    style={rgb ? { background: `rgb(${rgb.r} ${rgb.g} ${rgb.b})` } : undefined}
                  />
                  <strong>{index + 1}. {fixture.label}</strong>
                  <select
                    aria-label={`Role for ${fixture.label}`}
                    value={fixture.role}
                    disabled={state.running && fixture.role === 'off'}
                    title={ROLE_COPY[fixture.role].plain}
                    onChange={event => {
                      setFixtureRole(session, fixture.id, event.target.value as FixtureRole)
                      session.patch({})
                    }}
                  >
                    {ROLES.filter(role=>!state.running || role !== 'off' || fixture.role === 'off').map(role => (
                      <option key={role} value={role}>
                        {ROLE_COPY[role].name}
                      </option>
                    ))}
                  </select>
                  <div className="fixture-order">
                    <button disabled={index === 0} aria-label={`Move ${fixture.label} earlier`} onClick={() => moveFixture(fixture.id,-1)}>↑</button>
                    <button disabled={index === orderedFixtures.length - 1} aria-label={`Move ${fixture.label} later`} onClick={() => moveFixture(fixture.id,1)}>↓</button>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
        <details><summary>What the roles mean</summary><dl className="role-legend">
          {ROLES.map(role => (
            <div key={role}>
              <dt>{ROLE_COPY[role].name}</dt>
              <dd>{ROLE_COPY[role].plain}</dd>
            </div>
          ))}
        </dl></details>
      </div>
        </div>
      <div className="panel">
        <h2>Show balance</h2>
        <div className="music-adjustments">
          {([
            ['masterBrightness', 'Master brightness'], ['effectIntensity', 'Intensity'],
            ['beatSensitivity', 'Beat sensitivity'], ['movementAmount', 'Movement'],
            ['movementSpeed', 'Movement speed'], ['colorChangeIntensity', 'Color variation'],
          ] as const).map(([key, label]) => <label key={key} className="field">
            {label} <output>{Math.round(state.configuration[key] * 100)}%</output>
            <input aria-label={label} type="range" min="0" max={key === 'movementAmount' && reduceMotion ? '.2' : '1'} step=".01"
              value={state.configuration[key]} onChange={e => adjust(key, Number(e.target.value))}/>
          </label>)}
        </div>
        <h3>Color palette</h3>
        <div className="palette-choices">{[
          {name:'Aurora', colors:AURORA_PALETTE}, {name:'Sunset', colors:SUNSET_PALETTE},
          {name:'Ocean', colors:OCEAN_PALETTE}, {name:'Club', colors:CLUB_PALETTE},
        ].map(p => <button key={p.name} onClick={() => configure({...state.configuration, palette:p.colors, preset:'custom'})}
          aria-pressed={p.colors.map(c=>c.hex).join() === state.configuration.palette.map(c=>c.hex).join()}>
          <span className="palette-strip" aria-hidden="true">{p.colors.map((c,i)=><span key={i} style={{background:'#'+c.hex.toString(16).padStart(6,'0')}}/>)}</span>
          {p.name}
        </button>)}</div>
      </div>

      </div>
      <details className="panel">
        <summary>Music diagnostics</summary>
        <p>Source: {state.source} · snapshot age {session.diagnostics.snapshotAge.toFixed(3)} s · samples analyzed {session.diagnostics.analyzedSamples} · capture buffers dropped {session.diagnostics.droppedBuffers}</p>
        <p>Onset {(snapshot.onset ?? 0).toFixed(2)} · beat count {snapshot.beatCount} · confidence {snapshot.beatConfidence.toFixed(2)} · preset {state.configuration.preset}</p>
        <p>Grid phase now {snapshot.beatInterval > 0 ? (((performance.now()/1000-snapshot.beatReferenceTime)/snapshot.beatInterval)%1).toFixed(2) : "unlocked"} · last render interval {session.diagnostics.renderInterval.toFixed(3)} s (target 0.050 s) · effective brightness {state.configuration.masterBrightness.toFixed(2)} · intensity {state.configuration.effectIntensity.toFixed(2)}</p>
        <p>Generated {session.diagnostics.framesGenerated} · HTTP submitted {sender.diagnostics.submitted} · accepted {sender.diagnostics.accepted} · coalesced {sender.diagnostics.coalesced} · expired {sender.diagnostics.expired} · errors {sender.diagnostics.failures}</p>
        <p>Preview shows generated frames. HTTP acceptance does not establish device receipt or visible timing. Brightness modulation can still be uncomfortable with flashes disabled.</p>
      </details>
      <p className="meta">
        {MUSIC_HELP.strips} Colours go to the bridge on port {port}.
      </p>
    </section>
  )
}

function Meter({ label, value }: { label: string; value: number }) {
  return (
    <label className="field">
      {label}
      <meter min={0} max={1} value={Math.max(0, Math.min(1, value))} />
    </label>
  )
}

function sourceLabel(source: string, fileName: string | null): string {
  if (source === 'file') return fileName ?? 'Audio file'
  if (source === 'microphone') return 'Microphone'
  if (source === 'midi') return 'MIDI clock'
  return 'Demo groove'
}
