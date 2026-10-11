import { useCallback, useEffect, useRef, useState } from 'react'
import {
  type Device,
  type Room,
  type Scene,
  type Schedule,
  type DiscoveryResponse,
  DEFAULT_PORT,
  addSchedule,
  applyScene,
  assignRoom,
  checkHealth,
  createRoom,
  deleteRoom,
  deleteScene,
  deleteSchedule,
  detectSameOrigin,
  fetchState,
  renameDevice,
  saveScene,
  setBrightness,
  setColor,
  setKelvin,
  setPower,
  startDiscovery,
  toggleFavorite,
  updateSchedule,
  postMusicFrame,
  useSameOrigin,
  forgetShapes,
  identifyShapesPanel,
  pairShapes,
  paintShapes,
  playShapesScene,
  setShapesOrientation,
} from './bridge'
import { BridgeSetup, type BridgeState, describeFailure } from './BridgeSetup'
import {
  AutomationView,
  type Controls,
  DevicesView,
  HomeView,
  LibraryView,
  SettingsView,
} from './views'
import { MusicModeView, flushPendingMusicCleanup } from './MusicModeView'
import { RoomSetup } from './RoomSetup'
import { DiscoveryStatus } from './DiscoveryStatus'
import { countDiscoveryReplies } from './discovery'

type Destination = 'home' | 'library' | 'music' | 'automation' | 'devices' | 'settings'

const NAV: { id: Destination; label: string; icon: string }[] = [
  { id: 'home', label: 'Room', icon: '⌂' },
  { id: 'library', label: 'Scenes', icon: '' },
  { id: 'music', label: 'Music', icon: '♩' },
  { id: 'automation', label: 'Schedules', icon: '◷' },
  { id: 'devices', label: 'Devices', icon: '⌁' },
  { id: 'settings', label: 'Settings', icon: '⚙' },
]

const PORT_KEY = 'LumenDesk.bridgePort.v1'
const NAV_KEY = 'LumenDesk.destination.v1'
const POLL_MS = 1500
const SETUP_KEY = 'LumenDesk.roomSetupDismissed.v1'

function readStoredPort(): number {
  const value = Number(window.localStorage.getItem(PORT_KEY))
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_PORT
}

function readStoredDestination(): Destination {
  const stored = window.localStorage.getItem(NAV_KEY) as Destination | null
  return NAV.some(n => n.id === stored) ? (stored as Destination) : 'home'
}

export default function App() {
  const [port, setPort] = useState(readStoredPort)
  const [state, setState] = useState<BridgeState>('checking')
  const [destination, setDestination] = useState<Destination>(readStoredDestination)
  const [devices, setDevices] = useState<Device[]>([])
  const [rooms, setRooms] = useState<Room[]>([])
  const [scenes, setScenes] = useState<Scene[]>([])
  const [error, setError] = useState<string | null>(null)
  const [connectionError, setConnectionError] = useState<string | null>(null)
  const [hasConnected, setHasConnected] = useState(false)
  const [supportsRooms, setSupportsRooms] = useState(true)
  const [toast, setToast] = useState<string | null>(null)
  const [scanning, setScanning] = useState(false)
  const [attempts, setAttempts] = useState(0)
  const [servedByBridge, setServedByBridge] = useState(false)
  const [roomID, setRoomID] = useState('all')
  const [musicRunning, setMusicRunning] = useState(false)
  const [setupOpen, setSetupOpen] = useState(false)
  const [setupDismissed, setSetupDismissed] = useState(() => window.localStorage.getItem(SETUP_KEY) === 'true')
  const [discovery, setDiscovery] = useState<DiscoveryResponse | null>(null)
  const [scanAnswered, setScanAnswered] = useState<number | null>(null)
  const [discoveryError, setDiscoveryError] = useState<string | null>(null)
  // Ids with a command in flight, so a poll cannot overwrite an optimistic
  // value with a reading taken before the command landed.
  const inFlight = useRef(new Map<string, number>())
  // Each connection attempt owns its requests. An older response may settle
  // after a newer one, or after the user has selected another bridge.
  const connectionRef = useRef<{ port: number; requests: number; settled: number } | null>(null)

  useEffect(() => window.localStorage.setItem(PORT_KEY, String(port)), [port])
  useEffect(() => window.localStorage.setItem(NAV_KEY, destination), [destination])

  useEffect(() => {
    if (!toast) return undefined
    const timer = window.setTimeout(() => setToast(null), 2600)
    return () => window.clearTimeout(timer)
  }, [toast])

  const poll = useCallback(async () => {
    const connection = connectionRef.current
    if (!connection || connection.port !== port) return
    const request = ++connection.requests
    const isCurrent = () => connectionRef.current === connection && request >= connection.settled
    try {
      const next = await fetchState(port)
      if (!isCurrent()) return
      connection.settled = request
      setDevices(previous =>
        next.devices.map(device =>
          inFlight.current.has(device.id)
            ? (previous.find(p => p.id === device.id) ?? device)
            : device,
        ),
      )
      setRooms(next.rooms)
      setRoomID(current => current === 'all' || next.rooms.some(r => r.id === current) ? current : 'all')
      setScenes(next.scenes)
      setSupportsRooms(next.supportsRooms !== false)
      setState('connected')
      setHasConnected(true)
      setConnectionError(null)
      void flushPendingMusicCleanup(port, postMusicFrame)
      return next
    } catch (err) {
      if (!isCurrent()) return
      connection.settled = request
      setState('unavailable')
      setConnectionError(describeFailure(err))
      return null
    }
  }, [port])

  useEffect(() => {
    const connection = { port, requests: 0, settled: 0 }
    connectionRef.current = connection
    const isCurrent = () => connectionRef.current === connection
    setState('checking')
    void (async () => {
      try {
        const same = await detectSameOrigin()
        if (!isCurrent()) return
        useSameOrigin(same)
        setServedByBridge(same)
        await checkHealth(port)
        if (isCurrent()) await poll()
      } catch {
        if (isCurrent()) setState('unavailable')
      }
    })()
    return () => {
      connectionRef.current = null
    }
  }, [port, poll])

  useEffect(() => {
    if (state !== 'connected' && !hasConnected) return undefined
    const timer = window.setInterval(poll, state === 'connected' ? POLL_MS : 3000)
    return () => window.clearInterval(timer)
  }, [state, poll, hasConnected])

  useEffect(() => {
    if (state === 'connected' && supportsRooms && !rooms.length && !setupDismissed) setSetupOpen(true)
  }, [state, supportsRooms, rooms.length, setupDismissed])

  useEffect(() => {
    if (supportsRooms) return
    setSetupOpen(false)
    if (destination !== 'home' && destination !== 'settings') setDestination('home')
  }, [supportsRooms, destination])

  const connect = useCallback(async () => {
    const connection = { port, requests: 0, settled: 0 }
    connectionRef.current = connection
    const isCurrent = () => connectionRef.current === connection
    setState('checking')
    setConnectionError(null)
    try {
      await checkHealth(port)
      if (isCurrent()) await poll()
    } catch (err) {
      if (!isCurrent()) return
      setState('unavailable')
      setConnectionError(describeFailure(err))
      setAttempts(n => n + 1)
    }
  }, [port, poll])

  /** Optimistic device command: patch locally, send, reconcile, release. */
  const run = useCallback(
    async (device: Device, patch: Partial<Device>, action: () => Promise<Device>) => {
      inFlight.current.set(device.id, (inFlight.current.get(device.id) ?? 0) + 1)
      setError(null)
      setDevices(list => list.map(d => (d.id === device.id ? { ...d, ...patch } : d)))
      let succeeded = false
      try {
        const updated = await action()
        setDevices(list => list.map(d => (d.id === device.id ? { ...d, ...updated } : d)))
        succeeded = true
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
      } finally {
        const remaining = (inFlight.current.get(device.id) ?? 1) - 1
        if (remaining) inFlight.current.set(device.id, remaining)
        else inFlight.current.delete(device.id)
        if (!succeeded) void poll()
      }
      return succeeded
    },
    [poll],
  )

  /** Store-changing calls return the whole collection, so just adopt it. */
  const mutate = useCallback(
    async (action: () => Promise<unknown>, message?: string) => {
      setError(null)
      try {
        await action()
        await poll()
        if (message) setToast(message)
        return true
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
        return false
      }
    },
    [poll],
  )

  /** Shapes commands report their own failures, so they rethrow instead. */
  const adopt = useCallback(async (action: () => Promise<Device>) => {
    const updated = await action()
    setDevices(list => list.map(d => (d.id === updated.id ? { ...d, ...updated } : d)))
    return updated
  }, [])

  const scan = useCallback(async () => {
    setScanning(true)
    setDiscoveryError(null)
    setScanAnswered(null)
    const startedAt = Date.now()
    try {
      setDiscovery(await startDiscovery(port))
      await new Promise(r => setTimeout(r, 1500))
      const next = await poll()
      if (next) setScanAnswered(countDiscoveryReplies(next.devices, startedAt))
    } catch (err) {
      setDiscoveryError(err instanceof Error ? err.message : String(err))
    } finally {
      setScanning(false)
    }
  }, [port, poll])

  const controls: Controls = {
    power: (d, on) => run(d, { power: on }, () => setPower(port, d.id, on)),
    brightness: (d, value) => run(d, { brightness: value }, () => setBrightness(port, d.id, value)),
    color: (d, rgb) => run(d, { color: rgb }, () => setColor(port, d.id, rgb)),
    kelvin: (d, k) => run(d, { kelvin: k }, () => setKelvin(port, d.id, k)),
    favorite: d => mutate(() => toggleFavorite(port, d.id)),
    rename: (d, name) => mutate(() => renameDevice(port, d.id, name), `Renamed to ${name}`),
    assign: (d, roomID) => mutate(() => assignRoom(port, d.id, roomID)),
    shapes: d => ({
      orientation: degrees => adopt(() => setShapesOrientation(port, d.id, degrees)),
      paint: colors => adopt(() => paintShapes(port, d.id, colors)),
      play: name => adopt(() => playShapesScene(port, d.id, name)),
      identify: panelID => identifyShapesPanel(port, d.id, panelID),
    }),
  }

  const bulk = useCallback(
    async (ids: string[], action: 'on' | 'off') => {
      const targets = devices.filter(d => ids.includes(d.id) && d.reachable)
      const results = await Promise.all(
        targets.map(d => run(d, { power: action === 'on' }, () => setPower(port, d.id, action === 'on'))),
      )
      const sent = results.filter(Boolean).length
      const failed = results.length - sent
      setToast(`${action === 'on' ? 'On' : 'Off'} sent to ${sent} light${sent === 1 ? '' : 's'}${failed ? ` · ${failed} failed` : ''}`)
    },
    [devices, port, run],
  )

  if (state !== 'connected' && !hasConnected) {
    return (
      <BridgeSetup
        state={state}
        port={port}
        error={connectionError}
        attempts={attempts}
        servedByBridge={servedByBridge}
        onPort={setPort}
        onRetry={connect}
      />
    )
  }

  const reachable = devices.filter(d => d.reachable).length
  const room = rooms.find(r => r.id === roomID)
  const scopeName = room?.name ?? 'All lights'
  const scopedDevices = room ? devices.filter(d => room.lightIDs.includes(d.id)) : devices
  const inWorkspace = ['home', 'library', 'music'].includes(destination)
  const setupVisible = setupOpen && supportsRooms

  return (
    <div className="shell app">
      <nav className="workspace-nav" aria-label="Sections">
        <div className="brand">
          <span className="light-mark" aria-hidden="true" />
          <h1>LumenDesk</h1>
        </div>
        <ul>
          {NAV.filter(item => !['library', 'music'].includes(item.id) &&
            (supportsRooms || item.id === 'home' || item.id === 'settings')).map(item => (
            <li key={item.id}>
              <button
                className={(destination === item.id || (item.id === 'home' && inWorkspace)) ? 'nav active' : 'nav'}
                onClick={() => { setSetupOpen(false); setDestination(item.id) }}
                aria-current={(destination === item.id || (item.id === 'home' && inWorkspace)) ? 'page' : undefined}
              >
                {item.label}
              </button>
            </li>
          ))}
        </ul>
        <p className="sidebar-foot">
          {reachable} of {devices.length} online
          <br />
          Local control only
        </p>
      </nav>

      <main className="content">
        {state !== 'connected' && <div className="diagnostic" role="status">
          <p>{state === 'checking' ? 'Reconnecting to the bridge…' : `${connectionError ?? 'Bridge disconnected.'} Reconnecting automatically.`}</p>
          <p>Your edits are kept here. Light readings may be out of date; controls will return when the bridge reconnects.</p>
          <button onClick={connect} disabled={state === 'checking'}>Reconnect now</button>
        </div>}
        <header className="content-head">
          {inWorkspace ? <>
            <div>
              <label className="scope-label" htmlFor="room-scope">Control room</label>
              <select id="room-scope" className="room-scope" value={roomID} disabled={musicRunning}
                onChange={e => setRoomID(e.target.value)}>
                <option value="all">All lights</option>
                {rooms.map(r => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select>
              <p className="meta">{scopedDevices.filter(d => d.power && d.reachable).length} lit · {scopedDevices.length} fixtures · {scopedDevices.filter(d => !d.reachable).length} not responding</p>
              {musicRunning && <p className="note">Stop Music Mode before changing rooms.</p>}
            </div>
            <div className="toolbar">
              {supportsRooms && <button onClick={() => setSetupOpen(true)} disabled={musicRunning || state !== 'connected'}>Set up room</button>}
              <button onClick={scan} disabled={scanning || state !== 'connected'}>{scanning ? 'Searching…' : 'Find lights'}</button>
            </div>
          </> : <h1>{NAV.find(n => n.id === destination)?.label}</h1>}
        </header>
        {inWorkspace && supportsRooms && <nav className="workspace-sections" aria-label="Room controls">
          {(['home', 'library', 'music'] as const).map(id => <button key={id}
            aria-current={destination === id ? 'page' : undefined}
            onClick={() => { setSetupOpen(false); setDestination(id) }}>{id === 'home' ? 'Light' : id === 'library' ? 'Scenes' : 'Music'}</button>)}
        </nav>}

        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}

        <fieldset className="workspace-controls" disabled={state !== 'connected'} aria-label="Lighting workspace">
        {!supportsRooms && <p className="note" role="status">This older bridge supports basic lighting controls.
          Update it to use rooms, scenes, favorites, schedules and Music. <a href="https://github.com/SeanPVera/LumenDesk/releases">Get the current bridge</a>.</p>}
        {!setupVisible && <DiscoveryStatus scanning={scanning} result={discovery} answeredCount={scanAnswered}
          problem={discoveryError} onPair={supportsRooms ? () => setSetupOpen(true) : undefined} onRetry={scan} />}
        <RoomSetup open={setupVisible} devices={devices} rooms={rooms} scanning={scanning}
          discovery={discovery} answeredCount={scanAnswered} discoveryError={discoveryError}
          onScan={scan}
          onCreateRoom={async name => {
            let created: Room | null = null
            const saved = await mutate(async () => {
              const response = await createRoom(port, name)
              created = response.room
              setRooms(list => list.some(item => item.id === response.room.id) ? list : [...list, response.room])
            }, `Added ${name}`)
            return saved ? created : null
          }}
          onAssign={(device, targetRoomID) => mutate(() => assignRoom(port, device.id, targetRoomID))}
          onPower={(device, on) => run(device, { power: on }, () => setPower(port, device.id, on))}
          onBrightness={(device, value) => run(device, { brightness: value }, () => setBrightness(port, device.id, value))}
          onPairShapes={async (host, controllerPort) => {
            let paired: Device | null = null
            const saved = await mutate(async () => { paired = await pairShapes(port, host, controllerPort) })
            return saved ? paired : null
          }}
          onDone={targetRoomID => {
            setRoomID(targetRoomID)
            setDestination('home')
            setSetupOpen(false)
            setSetupDismissed(true)
            window.localStorage.setItem(SETUP_KEY, 'true')
          }}
          onCancel={() => {
            setSetupOpen(false)
            setSetupDismissed(true)
            window.localStorage.setItem(SETUP_KEY, 'true')
          }} />
        <div hidden={setupVisible}>
        {destination === 'home' && (
          <HomeView
            key={roomID}
            devices={scopedDevices}
            rooms={rooms}
            controls={controls}
            onBulk={bulk}
            onScan={scan}
            scanning={scanning}
            scopeName={scopeName}
            onSetupRoom={supportsRooms ? () => setSetupOpen(true) : undefined}
            supportsSavedLighting={supportsRooms}
            onSaveScene={name => mutate(() => saveScene(port, name, scopedDevices.map(d => d.id)), `Saved “${name}”`)}
          />
        )}
        {destination === 'library' && (
          <LibraryView
            scenes={scenes}
            devices={scopedDevices}
            allDevices={devices}
            rooms={rooms}
            scopeName={scopeName}
            onSave={name => mutate(() => saveScene(port, name, scopedDevices.map(d => d.id)), `Saved “${name}”`)}
            onApply={scene => mutate(async () => {
              const result = await applyScene(port, scene.id)
              setToast(`“${scene.name}”: sent to ${result.applied.length} light${result.applied.length === 1 ? '' : 's'}${result.skipped.length ? ` · ${result.skipped.length} skipped` : ''}`)
            })}
            onDelete={scene => mutate(() => deleteScene(port, scene.id), `Deleted “${scene.name}”`)}
          />
        )}
        {destination === 'music' && (
          <MusicModeView devices={scopedDevices} port={port} connected={state === 'connected'} postFrame={postMusicFrame} onRunningChange={setMusicRunning} />
        )}
        {destination === 'automation' && (
          <AutomationView
            rooms={rooms}
            scenes={scenes}
            onAdd={(roomID, entry) => mutate(() => addSchedule(port, roomID, entry), 'Schedule added')}
            onUpdate={(roomID, id, patch) => mutate(() => updateSchedule(port, roomID, id, patch), 'Schedule saved')}
            onDelete={(roomID, id) => mutate(() => deleteSchedule(port, roomID, id), 'Schedule removed')}
          />
        )}
        {destination === 'devices' && (
          <DevicesView
            devices={devices}
            rooms={rooms}
            controls={controls}
            onAddRoom={name => mutate(() => createRoom(port, name), `Added ${name}`)}
            onDeleteRoom={room => mutate(() => deleteRoom(port, room.id), `Deleted ${room.name}`)}
            onPairShapes={async (host, controllerPort) => {
              const device = await pairShapes(port, host, controllerPort)
              await poll()
              setToast(`Paired ${device.name}`)
            }}
            onForgetShapes={d => mutate(() => forgetShapes(port, d.id), `Forgot ${d.name}`)}
            onScan={scan}
            scanning={scanning}
          />
        )}
        {destination === 'settings' && (
          <SettingsView
            port={port}
            servedByBridge={servedByBridge}
            deviceCount={devices.length}
            onScan={scan}
            scanning={scanning}
          />
        )}
        </div>
        </fieldset>
      </main>

      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}
    </div>
  )
}
