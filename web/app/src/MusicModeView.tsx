import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { Device, RGB } from './bridge'
import { MUSIC_HELP, PRESET_COPY, ROLE_COPY, SOURCE_COPY, configurationFor } from './music/config'
import { GROOVES } from './music/grooves'
import { hsvToRgb } from './music/fixtures'
import { WebMusicSession, LatestMusicFrameSender, setFixtureRole, type MusicFrameCommand } from './music/session'
import type { FixtureRole, MusicModePreset } from './music/types'

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
}: {
  devices: Device[]
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
    snapshot.isTempoLocked && snapshot.tempo > 0
      ? `${Math.round(snapshot.feltTempo || snapshot.tempo)} · ${snapshot.metre}/${snapshot.metre === 6 ? 8 : 4}`
      : 'Beat'

  return (
    <section className="music-desk">
      <div className="panel">
        <p className="eyebrow">Music Mode</p>
        <h2>Your lights follow the music.</h2>
        <p>
          Pick a preset, then pick where the sound comes from. The music is analysed in this
          browser tab and never uploaded anywhere; only the resulting colours go to the bridge
          running on your own machine.
        </p>
        <ol className="steps">
          {MUSIC_HELP.steps.map(step => (
            <li key={step}>{step}</li>
          ))}
        </ol>
        <p className="note">{MUSIC_HELP.safety}</p>
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
              onClick={() => session.patch({ configuration: configurationFor(id) })}
            >
              {PRESET_COPY[id].name}
            </button>
          ))}
        </div>
        <p>{PRESET_COPY[presetCopyKey].plain}</p>
        <p className="meta">
          Good for: {PRESET_COPY[presetCopyKey].bestFor} · {PRESET_COPY[presetCopyKey].summary}
        </p>
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

      <details className="panel">
        <summary>Music diagnostics</summary>
        <p>Source: {state.source} · snapshot age {session.diagnostics.snapshotAge.toFixed(3)} s · samples analyzed {session.diagnostics.analyzedSamples} · capture buffers dropped {session.diagnostics.droppedBuffers}</p>
        <p>Onset {(snapshot.onset ?? 0).toFixed(2)} · beat count {snapshot.beatCount} · confidence {snapshot.beatConfidence.toFixed(2)} · preset {state.configuration.preset}</p>
        <p>Generated {session.diagnostics.framesGenerated} · HTTP submitted {sender.diagnostics.submitted} · accepted {sender.diagnostics.accepted} · coalesced {sender.diagnostics.coalesced} · expired {sender.diagnostics.expired} · errors {sender.diagnostics.failures}</p>
        <p>Preview shows generated frames. HTTP acceptance does not establish device receipt or visible timing. Brightness modulation can still be uncomfortable with flashes disabled.</p>
      </details>
      <div className="panel meters">
        <Meter label="Input" value={snapshot.level} />
        <Meter label="Bass" value={snapshot.bass} />
        <Meter label="Mids" value={snapshot.mids} />
        <Meter label="Highs" value={snapshot.highs} />
        <div className="beat-readout">
          <span className={`beat-dot${snapshot.beat > 0.25 ? ' lit' : ''}`} />
          <span>{tempo}</span>
        </div>
        <p className="note">{MUSIC_HELP.readout}</p>
      </div>

      <div className="panel">
        <p className="eyebrow">Which light does what</p>
        <p>{MUSIC_HELP.roles}</p>
        {state.fixtures.length === 0 ? (
          <p>No lights yet. Scan from Home, or run a demo groove to watch the lights move without any hardware.</p>
        ) : (
          <ul className="fixture-list">
            {state.fixtures.map(fixture => {
              const stateFor = state.frame?.states.find(s => s.fixtureID === fixture.id)
              const rgb = stateFor ? hsvToRgb(stateFor.hue, stateFor.saturation, stateFor.brightness) : null
              return (
                <li key={fixture.id}>
                  <span
                    className="fixture-swatch"
                    style={rgb ? { background: `rgb(${rgb.r} ${rgb.g} ${rgb.b})` } : undefined}
                  />
                  <strong>{fixture.label}</strong>
                  <select
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
                </li>
              )
            })}
          </ul>
        )}
        <dl className="role-legend">
          {ROLES.map(role => (
            <div key={role}>
              <dt>{ROLE_COPY[role].name}</dt>
              <dd>{ROLE_COPY[role].plain}</dd>
            </div>
          ))}
        </dl>
      </div>
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
