import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { fetchState, type Device, type RGB } from './bridge'
import { LATENCY_OFFSET_LIMIT, MUSIC_HELP, PRESET_COPY, ROLE_COPY, SOURCE_COPY, configurationFor, preservingRoomCalibration } from './music/config'
import { GROOVES } from './music/grooves'
import { hsvToRgb } from './music/fixtures'
import { WebMusicSession, LatestMusicFrameSender, setFixtureRole, type MusicFrameCommand } from './music/session'
import { TAP_MINIMUM } from './music/beat-map'
import { AURORA_PALETTE, SUNSET_PALETTE, OCEAN_PALETTE, CLUB_PALETTE, type AudioSourceKind, type FixtureRole, type MusicModePreset, type MusicModeConfiguration, type MusicFixtureDescriptor } from './music/types'


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

type MusicFramePoster = (port: number, states: MusicFrameCommand[]) => Promise<unknown>
type MusicCleanup = {
  port: number
  states: MusicFrameCommand[]
  ready: Promise<void>
  sending: boolean
  error: string | null
}

// Keep failed restoration/release work across Music tab navigation. These
// original owner/revision values let the bridge protect newer manual edits.
const pendingCleanups = new Map<string, MusicCleanup>()
const cleanupListeners = new Set<() => void>()
let cleanupVersion = 0
let cleanupFlight: { port: number; promise: Promise<boolean> } | null = null
const cleanupChanged = () => { cleanupVersion++; cleanupListeners.forEach(listener => listener()) }

/** Called after reconnection even when another tab is visible. */
export function flushPendingMusicCleanup(port: number, postFrame: MusicFramePoster): Promise<boolean> {
  if (cleanupFlight) {
    return cleanupFlight.port === port ? cleanupFlight.promise
      : cleanupFlight.promise.then(() => flushPendingMusicCleanup(port, postFrame))
  }
  const entries = [...pendingCleanups.entries()].filter(([, cleanup]) => cleanup.port === port)
  if (!entries.length) return Promise.resolve(true)
  const promise = (async () => {
    for (const [owner, cleanup] of entries) {
      try {
        await cleanup.ready
        cleanup.sending = true
        cleanupChanged()
        await postFrame(cleanup.port, cleanup.states)
        if (pendingCleanups.get(owner) === cleanup) pendingCleanups.delete(owner)
      } catch (err) {
        cleanup.error = err instanceof Error ? err.message : String(err)
        return false
      } finally {
        cleanup.sending = false
        cleanupChanged()
      }
    }
    return true
  })().finally(() => { cleanupFlight = null })
  cleanupFlight = { port, promise }
  return promise
}

export function MusicModeView({
  devices,
  port,
  connected = true,
  postFrame,
  onRunningChange,
}: {
  devices: Device[]
  onRunningChange?: (running: boolean) => void
  port: number
  connected?: boolean
  postFrame: MusicFramePoster
}) {
  const sessionRef = useRef<WebMusicSession | null>(null)
  if (!sessionRef.current) sessionRef.current = new WebMusicSession()
  const session = sessionRef.current
  // Controls change on user actions, independently of the 20 Hz light frames.
  useSyncExternalStore(
    useCallback(listener => session.subscribeControls(listener), [session]),
    () => session.controlsVersion,
    () => session.controlsVersion,
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
  const [selectedSource, setSelectedSource] = useState<AudioSourceKind>(state.source)
  const [file, setFile] = useState<File | null>(null)
  const [selectedGroove, setSelectedGroove] = useState(state.grooveId)
  const [starting, setStarting] = useState(false)
  const [stopSummary, setStopSummary] = useState<string | null>(null)
  const busy = state.running || starting
  useEffect(() => { onRunningChange?.(busy); return () => onRunningChange?.(false) }, [busy, onRunningChange])
  const activeFile = useRef<File | null>(null)
  const reachable = devices.filter(d => d.reachable)
  const reachableRef = useRef(reachable)
  reachableRef.current = reachable
  useSyncExternalStore(
    listener => { cleanupListeners.add(listener); return () => { cleanupListeners.delete(listener) } },
    () => cleanupVersion,
    () => cleanupVersion,
  )
  const cleanups = [...pendingCleanups.values()].filter(cleanup => cleanup.port === port)
  const cleanupBusy = cleanups.some(cleanup => cleanup.sending)
  const cleanupError = cleanups.find(cleanup => cleanup.error)?.error
  const cleanupRestores = cleanups.some(cleanup => cleanup.states.some(command => command.restoring))

  // Restore color and independent brightness only while this session still
  // owns the fixture. The bridge rejects restoration after a newer manual edit.
  const baseline = useRef<MusicFrameCommand[] | null>(null)
  const baselineRevisions = useRef(new Map<string, number | undefined>())
  const senderRef = useRef<LatestMusicFrameSender | null>(null)
  const postRef = useRef(postFrame); postRef.current=postFrame
  const portRef = useRef(port); portRef.current=port
  const connectedRef = useRef(connected); connectedRef.current=connected
  const owner = useRef(crypto.randomUUID())
  if (!senderRef.current) senderRef.current = new LatestMusicFrameSender(states=>postRef.current(portRef.current,states.map(state=>({
    ...state,owner:owner.current,controlRevision:baselineRevisions.current.get(state.fixtureID)
  }))))
  const sender=senderRef.current
  const transition = useRef(Promise.resolve())
  const transitionEpoch = useRef(0)
  const restoration = useRef(Promise.resolve())

  const restoreBaseline = (
    previous: MusicFrameCommand[] | null,
    restore: boolean,
    captureStopped = Promise.resolve(),
  ) => {
    // Record cleanup immediately, then drain both capture and queued frames.
    // Every Stop/Start also waits for a restoration already in flight.
    const ready = Promise.all([captureStopped, sender.stop(), restoration.current]).then(() => undefined)
    if (previous?.length) {
      pendingCleanups.set(owner.current, {
        port: portRef.current,
        states: restore ? previous : previous.map(command => ({ ...command, restoring: false, release: true })),
        ready, sending: false, error: null,
      })
      cleanupChanged()
    }
    const epoch = transitionEpoch.current
    restoration.current = ready.then(async () => {
      const finished = connectedRef.current && await flushPendingMusicCleanup(portRef.current, postRef.current)
      if (finished && epoch === transitionEpoch.current && previous?.length) {
        setStopSummary(restore ? 'Music stopped. Starting color and brightness sent to the bridge.' : 'Music stopped. Lights released at their last music output.')
      }
    })
    return restoration.current
  }

  const start = () => {
    const source = selectedSource
    const audio = source === 'file' ? file ?? undefined : undefined
    if (source === 'file' && !audio) return
    const epoch = ++transitionEpoch.current
    setStarting(true)
    setStopSummary(null)
    transition.current = transition.current.then(async () => {
      if (epoch !== transitionEpoch.current) return
      await restoration.current
      if (epoch !== transitionEpoch.current) return
      await sender.stop()
      if (epoch !== transitionEpoch.current) return
      if (!connectedRef.current || !await flushPendingMusicCleanup(portRef.current, postRef.current)) return
      if (epoch !== transitionEpoch.current || !connectedRef.current) return
      // Restart retains the original output. After Stop or a failed capture,
      // read the bridge: the page may still show the previous show's colors.
      if (!baseline.current) {
        let current: Device[]
        try {
          current = (await fetchState(portRef.current)).devices
        } catch (err) {
          if (epoch === transitionEpoch.current) session.patch({ error: err instanceof Error ? err.message : String(err) })
          return
        }
        if (epoch !== transitionEpoch.current || !connectedRef.current) return
        // Room selection can change during this read. Snapshot and render the
        // latest room together, retaining the user's roles for existing lights.
        const scoped = reachableRef.current
        session.setDevices(scoped.map(d => ({ id: d.id, name: d.name, brand: d.brand, reachable: d.reachable })))
        const includedIDs = new Set(session.state.fixtures.filter(fixture => fixture.role !== 'off').map(fixture => fixture.id))
        baseline.current = current
          .filter((d): d is Device & { color: RGB } => d.reachable && Boolean(d.color) && includedIDs.has(d.id))
          .map(d => ({ fixtureID: d.id, rgb: d.color, brightness:d.brightness/100,restoring:true,owner:owner.current,controlRevision:d.controlRevision ?? 0 }))
        baselineRevisions.current = new Map(baseline.current.map(frame => [frame.fixtureID, frame.controlRevision]))
      }
      session.patch({ grooveId: selectedGroove })
      await session.start(source, audio)
      if (epoch !== transitionEpoch.current) return
      if (session.state.running) {
        activeFile.current = source === 'file' ? audio ?? null : null
        sender.start()
      } else {
        // Failed Restart must put back the first show's output too. Preserve
        // owner/revision information in the retry queue until rollback finishes.
        const previous = baseline.current
        baseline.current = null
        baselineRevisions.current.clear()
        setStarting(false)
        await restoreBaseline(previous, state.configuration.restorePreviousState)
      }
    }).finally(() => {
      if (epoch === transitionEpoch.current) setStarting(false)
    })
    return transition.current
  }

  const stop = () => {
    ++transitionEpoch.current
    setStarting(false)
    const previous = baseline.current
    baseline.current = null
    baselineRevisions.current.clear()
    // Invalidate permission/capture synchronously. A cancelled start cannot
    // later roll back a replacement show when its permission request settles.
    const captureStopped = session.stop()
    transition.current = restoreBaseline(previous, state.configuration.restorePreviousState, captureStopped)
    return transition.current
  }

  // Leaving the tab or navigating away is a stop too, so the lights are not
  // abandoned mid-show.
  const stopRef = useRef(stop)
  stopRef.current = stop
  useEffect(() => () => { void stopRef.current() }, [])
  useEffect(() => {
    if (!connected) void stopRef.current()
    else void flushPendingMusicCleanup(portRef.current, postRef.current)
  }, [connected])

  useEffect(() => {
    const memberIDs = new Set(session.state.fixtures.map(fixture => fixture.id))
    session.setDevices(reachable
      .filter(device => (!starting && !state.running) || memberIDs.has(device.id))
      .map(d => ({ id: d.id, name: d.name, brand: d.brand, reachable: d.reachable })))
  }, [session, starting, state.running, reachable.map(d => d.id).join('|')])

  useEffect(() => {
    session.setOnFrame(frame => sender.enqueue(frame))
    return () => session.setOnFrame(null)
  }, [session, sender])

  const includedFixtures = state.fixtures.filter(fixture => fixture.role !== 'off')
  const unpoweredFixtures = reachable.filter(device => !device.power && includedFixtures.some(fixture => fixture.id === device.id))
  const pendingSource = state.running && (selectedSource !== state.source
    || (selectedSource === 'file' && file !== activeFile.current)
    || (selectedSource === 'demo' && selectedGroove !== state.grooveId))
  const startDisabled = starting || !connected || cleanupBusy || (selectedSource === 'file' && !file)
    || (!includedFixtures.length && selectedSource !== 'demo')

  const presetCopyKey = state.configuration.preset === 'custom' ? 'balanced' : state.configuration.preset

  return (
    <section className={`music-desk${state.running || starting ? ' is-running' : ''}`}>
      <div className="panel music-source">
        <p className="eyebrow">Music Mode</p>
        <h2>{state.running ? 'Music is controlling the included lights' : 'Set up your music show'}</h2>
        <details><summary>Sources, getting started, and flash limits</summary>
          <p>Audio is analyzed locally in this tab. Only lighting commands go to your bridge.</p>
          <ol className="steps">{MUSIC_HELP.steps.map(step => <li key={step}>{step}</li>)}</ol>
          <p>{MUSIC_HELP.safety}</p>
        </details>
        <h3>1. Choose a source</h3>
        <div className="music-toolbar" role="group" aria-label="Music source">
          {(['demo', 'microphone', 'file', 'midi'] as const).map(source => (
            <button
              key={source}
              onClick={() => setSelectedSource(source)}
              className={selectedSource === source ? 'nav active' : 'nav'}
              aria-pressed={selectedSource === source}
              title={SOURCE_COPY[source].plain}
            >
              {SOURCE_COPY[source].name}
            </button>
          ))}
        </div>
        <p className="note">{SOURCE_COPY[selectedSource].plain}</p>
        {selectedSource === 'file' && <div>
          <label className="file-key">
            Choose audio file
            <input
              aria-label="Choose audio file"
              type="file"
              accept="audio/*"
              onChange={event => {
                const next = event.target.files?.[0]
                if (!next) return
                setFile(next)
                setSelectedSource('file')
              }}
            />
          </label>
          <p className="meta">{file ? `Selected: ${file.name}` : 'Choose a file before pressing Start.'}</p>
        </div>}
        {selectedSource === 'demo' && <label className="field">
          Demo groove
          <select value={selectedGroove} onChange={event => setSelectedGroove(event.target.value)}>
            {GROOVES.map(groove => <option key={groove.id} value={groove.id}>
              {groove.name} — {groove.summary}
            </option>)}
          </select>
        </label>}
        {pendingSource && <p className="note" role="status">
          Selected for the next start: {sourceLabel(selectedSource, file?.name ?? null)}. The current source keeps running until you press Restart.
        </p>}
      </div>

      <div className="panel">
        <h3>2. Choose a preset</h3>
        <div className="chip-row">
          {PRESETS.map(id => (
            <button
              key={id}
              className={state.configuration.preset === id ? 'chip on' : 'chip'}
              aria-pressed={state.configuration.preset === id}
              onClick={() => configure(preservingRoomCalibration(configurationFor(id), state.configuration))}
            >
              {PRESET_COPY[id].name}
            </button>
          ))}
        </div>
        <p>{state.configuration.preset === 'custom' ? 'Custom balance. Choosing a preset replaces these adjustments.' : PRESET_COPY[presetCopyKey].plain}</p>
      </div>


      <div className="panel">
        <h3>3. Choose lights and roles</h3>
        <p className="note">Music follows the room selection above. Choose Off to leave a light out; the other roles control how it responds. {state.running ? 'Stop before including or excluding lights.' : 'Assign roles before pressing Start.'}</p>
        <p className="meta">{includedFixtures.length} included {includedFixtures.length === 1 ? 'light' : 'lights'} · {state.fixtures.length - includedFixtures.length} left out</p>
        {unpoweredFixtures.length > 0 && <p className="note" role="status">{unpoweredFixtures.length} included {unpoweredFixtures.length === 1 ? 'light is' : 'lights are'} off. Turn {unpoweredFixtures.length === 1 ? 'it' : 'them'} on in Room before starting; Music changes color and brightness without switching power on.</p>}
        {state.fixtures.length === 0 ? (
          <p>No lights yet. Use Find lights in Room, or choose Demo groove and press Start to try the input meters without hardware.</p>
        ) : (
          <FixturePreview session={session} fixtures={orderedFixtures} moveFixture={moveFixture} />
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

      <div className="panel music-transport">
        <h3>4. Start the show</h3>
        <p className="note">{reduceMotion ? "Reduced Motion: flashes blocked; movement limited." : state.configuration.photosensitivitySafeMode ? "No-flash mode: explicit flashes blocked." : "Controlled flashes enabled."} Brightness changes can still be uncomfortable. {state.configuration.restorePreviousState ? 'Stop sends the starting output back; a newer manual edit takes priority.' : 'Stop leaves the lights at their last music output.'}</p>
        <div className="music-toolbar">
          <button className="primary" disabled={startDisabled} onClick={() => void start()}>
            {starting ? 'Starting…' : state.running ? 'Restart' : 'Start'}
          </button>
          <button onClick={() => void stop()} disabled={!state.running && !starting && !baseline.current?.length}>Stop</button>
        </div>
        <p className="meta" role="status">
          {starting ? 'Starting' : state.running ? 'Running' : 'Idle'} · {state.running ? sourceLabel(state.source, state.fileName) : sourceLabel(selectedSource, file?.name ?? null)} · {includedFixtures.length} included lights
          {state.midiClock ? ' · MIDI' : ''}
        </p>
        {!connected && <p className="note">Reconnect the bridge before starting Music.</p>}
        {!includedFixtures.length && selectedSource !== 'demo' && <p className="note">Find lights in Room or change a light’s role from Off before starting. Demo groove can run without lights.</p>}
        {state.error && <p className="error" role="alert">{state.error}</p>}
        {stopSummary && cleanups.length === 0 && <p className="note" role="status">{stopSummary}</p>}
        {cleanups.length > 0 && <div className="diagnostic" role={cleanupError ? 'alert' : 'status'}>
          <p>Music stopped. {cleanupRestores ? 'Sending the starting light output back' : 'Releasing Music Mode’s lights'} is {cleanupBusy ? 'in progress' : 'still pending'}.</p>
          {cleanupError && <p>{cleanupError}</p>}
          <p>This retries when the bridge reconnects. Another show waits for this step to finish.</p>
          <button disabled={!connected || cleanupBusy} onClick={() => void flushPendingMusicCleanup(portRef.current, postRef.current)}>
            {cleanupBusy ? 'Sending…' : 'Retry now'}
          </button>
        </div>}
      </div>

      <div className="music-performance">
        <div className="music-output">
          <MusicMeters session={session} />
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
        <label className="field">
          Light timing <output>{timingLabel(state.configuration.outputLatencyOffset)}</output>
          <input aria-label="Light timing" aria-describedby="light-timing-help" type="range"
            min={-LATENCY_OFFSET_LIMIT * 1000} max={LATENCY_OFFSET_LIMIT * 1000} step="10"
            value={Math.round(state.configuration.outputLatencyOffset * 1000)}
            onChange={e => configure({ ...state.configuration, outputLatencyOffset: Number(e.target.value) / 1000 })}/>
        </label>
        <p className="note" id="light-timing-help">{MUSIC_HELP.timing}</p>
        <TimingCalibration session={session}
          apply={offset => configure({ ...state.configuration, outputLatencyOffset: offset })} />
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
      <MusicDiagnostics session={session} sender={sender} />
      <p className="meta">
        {MUSIC_HELP.strips} Colours go to the bridge on port {port}.
      </p>
    </section>
  )
}

// Only the live readouts subscribe to the frame clock. Sliders, palettes and
// fixture assignments remain stable while the lighting engine runs at 20 Hz.
function useMusicFrame(session: WebMusicSession) {
  useSyncExternalStore(
    useCallback(listener => session.subscribe(listener), [session]),
    () => session.version,
    () => session.version,
  )
}

function MusicMeters({ session }: { session: WebMusicSession }) {
  useMusicFrame(session)
  const { snapshot, running, source, beatMap } = session.state
  const [expanded, setExpanded] = useState(false)
  const tempo = snapshot.isTempoLocked && snapshot.tempo > 0 && snapshot.beatConfidence >= .4
    ? `${Math.round(snapshot.feltTempo || snapshot.tempo)} · ${snapshot.metre}/${snapshot.metre === 6 ? 8 : 4}`
    : 'Beat'
  return <div className="panel meters">
    <Meter label="Input" value={snapshot.level} />
    <Meter label="Energy" value={snapshot.energy} />
    <div className="beat-readout">
      <strong>{!running ? 'Stopped' : tempo === 'Beat' ? 'Finding a pulse' : tempo}</strong>
      <span>{source === 'midi' ? 'Measured MIDI clock · ' : snapshot.beatMapActive ? 'Following the beat map · ' : ''}Confidence {Math.round(snapshot.beatConfidence * 100)}%</span>
    </div>
    {running && source === 'file' && <p className="meta" role="status">{beatMapLabel(beatMap)}</p>}
    <p className="note">Audio input and musical interpretation. Generated colors in the light list are not device confirmations.</p>
    <details onToggle={event => setExpanded(event.currentTarget.open)}>
      <summary>Audio diagnostics</summary>
      {expanded && <><Meter label="Bass" value={snapshot.bass}/><Meter label="Mids" value={snapshot.mids}/><Meter label="Highs" value={snapshot.highs}/></>}
    </details>
  </div>
}

function FixturePreview({ session, fixtures, moveFixture }: {
  session: WebMusicSession
  fixtures: MusicFixtureDescriptor[]
  moveFixture: (id: string, offset: number) => void
}) {
  const swatches = useRef(new Map<string, HTMLSpanElement>())
  useEffect(() => {
    const colors = new Map<string, string>()
    const refresh = () => {
      colors.clear()
      // Match the first generated state per fixture without repeatedly scanning
      // every segment, and update just the painted swatches between UI edits.
      for (const state of session.state.frame?.states ?? []) {
        if (colors.has(state.fixtureID)) continue
        const rgb = hsvToRgb(state.hue, state.saturation, state.brightness)
        colors.set(state.fixtureID, `rgb(${rgb.r}, ${rgb.g}, ${rgb.b})`)
      }
      for (const [id, swatch] of swatches.current) {
        const color = colors.get(id) ?? ''
        if (swatch.style.backgroundColor !== color) swatch.style.backgroundColor = color
      }
    }
    refresh()
    return session.subscribe(refresh)
  }, [session])
  const running = session.state.running
  return <ul className="fixture-list">
    {fixtures.map((fixture, index) => <li key={fixture.id}>
      <span className="fixture-swatch" ref={element => {
        if (element) swatches.current.set(fixture.id, element)
        else swatches.current.delete(fixture.id)
      }} />
      <strong>{index + 1}. {fixture.label}</strong>
      <select
        aria-label={`Role for ${fixture.label}`}
        value={fixture.role}
        disabled={running && fixture.role === 'off'}
        title={ROLE_COPY[fixture.role].plain}
        onChange={event => {
          setFixtureRole(session, fixture.id, event.target.value as FixtureRole)
          session.patch({})
        }}
      >
        {ROLES.filter(role => !running || role !== 'off' || fixture.role === 'off').map(role => (
          <option key={role} value={role}>{ROLE_COPY[role].name}</option>
        ))}
      </select>
      <div className="fixture-order">
        <button disabled={index === 0} aria-label={`Move ${fixture.label} earlier`} onClick={() => moveFixture(fixture.id, -1)}>↑</button>
        <button disabled={index === fixtures.length - 1} aria-label={`Move ${fixture.label} later`} onClick={() => moveFixture(fixture.id, 1)}>↓</button>
      </div>
    </li>)}
  </ul>
}

function MusicDiagnostics({ session, sender }: { session: WebMusicSession; sender: LatestMusicFrameSender }) {
  const [expanded, setExpanded] = useState(false)
  return <details className="panel" onToggle={event => setExpanded(event.currentTarget.open)}>
    <summary>Music diagnostics</summary>
    {expanded && <MusicDiagnosticsReadout session={session} sender={sender} />}
  </details>
}

function MusicDiagnosticsReadout({ session, sender }: { session: WebMusicSession; sender: LatestMusicFrameSender }) {
  useMusicFrame(session)
  const state = session.state
  const snapshot = state.snapshot
  return <>
    <p>Source: {state.source} · snapshot age {session.diagnostics.snapshotAge.toFixed(3)} s · samples analyzed {session.diagnostics.analyzedSamples} · capture buffers dropped {session.diagnostics.droppedBuffers}</p>
    <p>Onset {(snapshot.onset ?? 0).toFixed(2)} · beat count {snapshot.beatCount} · confidence {snapshot.beatConfidence.toFixed(2)} · preset {state.configuration.preset}</p>
    <p>Grid phase now {snapshot.beatInterval > 0 ? (((performance.now()/1000-snapshot.beatReferenceTime)/snapshot.beatInterval)%1).toFixed(2) : "unlocked"} · last render interval {session.diagnostics.renderInterval.toFixed(3)} s (target 0.050 s) · effective brightness {state.configuration.masterBrightness.toFixed(2)} · intensity {state.configuration.effectIntensity.toFixed(2)} · energy gear {state.frame?.energyTier ?? '–'} of 5 · grid {snapshot.beatMapActive ? 'beat map' : 'live'}</p>
    <p>Generated {session.diagnostics.framesGenerated} · HTTP submitted {sender.diagnostics.submitted} · accepted {sender.diagnostics.accepted} · coalesced {sender.diagnostics.coalesced} · expired {sender.diagnostics.expired} · errors {sender.diagnostics.failures}</p>
    <p>Preview shows generated frames. HTTP acceptance does not establish device receipt or visible timing. Brightness modulation can still be uncomfortable with flashes disabled.</p>
  </>
}

function Meter({ label, value }: { label: string; value: number }) {
  return (
    <label className="field">
      {label}
      <meter min={0} max={1} value={Math.max(0, Math.min(1, value))} />
    </label>
  )
}

/** Tap along with the lights to measure how late they land, then adopt the measurement. */
function TimingCalibration({ session, apply }: { session: WebMusicSession; apply: (offset: number) => void }) {
  useMusicFrame(session)
  const count = session.calibrationTapCount
  const suggested = session.calibratedLatencyOffset()
  const status = !session.state.running ? 'Start a show to calibrate'
    : !session.canCalibrate ? 'Waiting for a steady beat'
    : count < TAP_MINIMUM ? `${count} of ${TAP_MINIMUM} taps`
    : suggested != null ? `Measured: ${timingLabel(suggested)}`
    : `${count} taps, too uneven. Keep tapping.`
  return <>
    <div className="row" role="group" aria-label="Measure light timing">
      <button disabled={!session.canCalibrate} aria-describedby="calibration-help"
        onClick={() => session.recordCalibrationTap()}>Tap with the lights</button>
      <span className="meta" role="status">{status}</span>
      {count > 0 && <button onClick={() => session.resetCalibrationTaps()}>Start over</button>}
      <button disabled={suggested == null} onClick={() => {
        if (suggested == null) return
        apply(suggested)
        session.resetCalibrationTaps()
      }}>Use measured timing</button>
    </div>
    <p className="note" id="calibration-help">{MUSIC_HELP.calibration}</p>
  </>
}

function timingLabel(offset: number): string {
  const ms = Math.round(offset * 1000)
  if (ms === 0) return 'On the beat'
  return ms > 0 ? `${ms} ms earlier` : `${-ms} ms later`
}

function beatMapLabel(beatMap: { status: string; progress: number; tempo: number | null }): string {
  switch (beatMap.status) {
    case 'analyzing': return `Mapping beats… ${Math.round(beatMap.progress * 100)}%. Live listening runs meanwhile.`
    case 'ready': return `Beat map ready${beatMap.tempo ? ` · ${Math.round(beatMap.tempo)} BPM` : ''}. ${MUSIC_HELP.beatMap}`
    case 'unavailable': return 'No steady beat found in this file, so the show keeps listening live.'
    default: return ''
  }
}

function sourceLabel(source: string, fileName: string | null): string {
  if (source === 'file') return fileName ?? 'Audio file'
  if (source === 'microphone') return 'Microphone'
  if (source === 'midi') return 'MIDI clock'
  return 'Demo groove'
}
