import { useCallback, useEffect, useRef, useState } from 'react'
import {
  type Device,
  type Room,
  type Scene,
  type Schedule,
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
  useSameOrigin,
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

type Destination = 'home' | 'library' | 'automation' | 'devices' | 'settings'

const NAV: { id: Destination; label: string; icon: string }[] = [
  { id: 'home', label: 'Home', icon: '⌂' },
  { id: 'library', label: 'Library', icon: '✦' },
  { id: 'automation', label: 'Automation', icon: '◷' },
  { id: 'devices', label: 'Devices', icon: '⌁' },
  { id: 'settings', label: 'Settings', icon: '⚙' },
]

const PORT_KEY = 'LumenDesk.bridgePort.v1'
const NAV_KEY = 'LumenDesk.destination.v1'
const POLL_MS = 1500

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
  const [toast, setToast] = useState<string | null>(null)
  const [scanning, setScanning] = useState(false)
  const [attempts, setAttempts] = useState(0)
  const [servedByBridge, setServedByBridge] = useState(false)
  // Ids with a command in flight, so a poll cannot overwrite an optimistic
  // value with a reading taken before the command landed.
  const inFlight = useRef(new Set<string>())

  useEffect(() => window.localStorage.setItem(PORT_KEY, String(port)), [port])
  useEffect(() => window.localStorage.setItem(NAV_KEY, destination), [destination])

  useEffect(() => {
    if (!toast) return undefined
    const timer = window.setTimeout(() => setToast(null), 2600)
    return () => window.clearTimeout(timer)
  }, [toast])

  const poll = useCallback(async () => {
    try {
      const next = await fetchState(port)
      setDevices(previous =>
        next.devices.map(device =>
          inFlight.current.has(device.id)
            ? (previous.find(p => p.id === device.id) ?? device)
            : device,
        ),
      )
      setRooms(next.rooms)
      setScenes(next.scenes)
      setState('connected')
      setError(null)
    } catch (err) {
      setState('unavailable')
      setError(describeFailure(err))
    }
  }, [port])

  useEffect(() => {
    let cancelled = false
    setState('checking')
    detectSameOrigin()
      .then(same => {
        useSameOrigin(same)
        if (same) setServedByBridge(true)
        return checkHealth(port)
      })
      .then(() => {
        if (!cancelled) poll()
      })
      .catch(() => {
        if (!cancelled) setState('unavailable')
      })
    return () => {
      cancelled = true
    }
  }, [port, poll])

  useEffect(() => {
    if (state !== 'connected') return undefined
    const timer = window.setInterval(poll, POLL_MS)
    return () => window.clearInterval(timer)
  }, [state, poll])

  const connect = useCallback(async () => {
    setState('checking')
    setError(null)
    try {
      await checkHealth(port)
      await poll()
    } catch (err) {
      setState('unavailable')
      setError(describeFailure(err))
      setAttempts(n => n + 1)
    }
  }, [port, poll])

  /** Optimistic device command: patch locally, send, reconcile, release. */
  const run = useCallback(
    async (device: Device, patch: Partial<Device>, action: () => Promise<Device>) => {
      inFlight.current.add(device.id)
      setDevices(list => list.map(d => (d.id === device.id ? { ...d, ...patch } : d)))
      try {
        const updated = await action()
        setDevices(list => list.map(d => (d.id === device.id ? { ...d, ...updated } : d)))
        setError(null)
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
        poll()
      } finally {
        inFlight.current.delete(device.id)
      }
    },
    [poll],
  )

  /** Store-changing calls return the whole collection, so just adopt it. */
  const mutate = useCallback(
    async (action: () => Promise<unknown>, message?: string) => {
      try {
        await action()
        await poll()
        if (message) setToast(message)
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
      }
    },
    [poll],
  )

  const scan = useCallback(async () => {
    setScanning(true)
    try {
      await startDiscovery(port)
      await new Promise(r => setTimeout(r, 1500))
      await poll()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
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
  }

  const bulk = useCallback(
    async (ids: string[], action: 'on' | 'off') => {
      const targets = devices.filter(d => ids.includes(d.id) && d.reachable)
      await Promise.all(
        targets.map(d => run(d, { power: action === 'on' }, () => setPower(port, d.id, action === 'on'))),
      )
      setToast(`${targets.length} light${targets.length === 1 ? '' : 's'} turned ${action}`)
    },
    [devices, port, run],
  )

  if (state !== 'connected') {
    return (
      <BridgeSetup
        state={state}
        port={port}
        error={error}
        attempts={attempts}
        servedByBridge={servedByBridge}
        onPort={setPort}
        onRetry={connect}
      />
    )
  }

  const reachable = devices.filter(d => d.reachable).length

  return (
    <div className="shell app">
      <nav className="sidebar" aria-label="Sections">
        <div className="brand">
          <span className="dot" aria-hidden="true" />
          <h1>LumenDesk</h1>
        </div>
        <ul>
          {NAV.map(item => (
            <li key={item.id}>
              <button
                className={destination === item.id ? 'nav active' : 'nav'}
                onClick={() => setDestination(item.id)}
                aria-current={destination === item.id ? 'page' : undefined}
              >
                <span aria-hidden="true">{item.icon}</span>
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
        <header className="content-head">
          <h1>{NAV.find(n => n.id === destination)?.label}</h1>
        </header>

        {error && (
          <p className="error" role="alert">
            {error}
          </p>
        )}

        {destination === 'home' && (
          <HomeView
            devices={devices}
            rooms={rooms}
            controls={controls}
            onBulk={bulk}
            onScan={scan}
            scanning={scanning}
          />
        )}
        {destination === 'library' && (
          <LibraryView
            scenes={scenes}
            devices={devices}
            onSave={name => mutate(() => saveScene(port, name), `Saved “${name}”`)}
            onApply={scene => mutate(() => applyScene(port, scene.id), `Applied “${scene.name}”`)}
            onDelete={scene => mutate(() => deleteScene(port, scene.id), `Deleted “${scene.name}”`)}
          />
        )}
        {destination === 'automation' && (
          <AutomationView
            rooms={rooms}
            scenes={scenes}
            onAdd={(roomID, entry) => mutate(() => addSchedule(port, roomID, entry), 'Schedule added')}
            onUpdate={(roomID, id, patch) => {
              // Reflect the toggle immediately; the poll reconciles it.
              setRooms(list =>
                list.map(r =>
                  r.id === roomID
                    ? { ...r, schedules: r.schedules.map(s => (s.id === id ? { ...s, ...patch } : s)) }
                    : r,
                ),
              )
              return mutate(() => updateSchedule(port, roomID, id, patch))
            }}
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
      </main>

      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}
    </div>
  )
}
