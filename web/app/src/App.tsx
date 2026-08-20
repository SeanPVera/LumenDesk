import { useCallback, useEffect, useRef, useState } from 'react'
import {
  DEFAULT_PORT,
  type Device,
  type RGB,
  checkHealth,
  fetchDevices,
  healthURL,
  hexToRGB,
  rgbToHex,
  setBrightness,
  setColor,
  setKelvin,
  setPower,
  startDiscovery,
} from './bridge'

type BridgeState = 'checking' | 'connected' | 'unavailable'

const PORT_KEY = 'LumenDesk.bridgePort.v1'
const POLL_MS = 1000

const PRESETS: { label: string; rgb: RGB }[] = [
  { label: 'Warm', rgb: { r: 255, g: 176, b: 92 } },
  { label: 'Amber', rgb: { r: 231, g: 179, b: 90 } },
  { label: 'Cyan', rgb: { r: 115, g: 180, b: 189 } },
  { label: 'Green', rgb: { r: 131, g: 182, b: 122 } },
  { label: 'Copper', rgb: { r: 201, g: 120, b: 82 } },
  { label: 'Cool', rgb: { r: 220, g: 232, b: 255 } },
]

/** A blocked local-network request and a bridge that is not running both
 *  surface as an opaque TypeError, so the message stays honest about that. */
function describeFailure(err: unknown): string {
  if (err instanceof DOMException && err.name === 'TimeoutError') {
    return 'The bridge did not answer in time.'
  }
  return 'Could not reach the bridge.'
}

function readStoredPort(): number {
  const raw = window.localStorage.getItem(PORT_KEY)
  const value = Number(raw)
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_PORT
}

export default function App() {
  const [port, setPort] = useState(readStoredPort)
  const [state, setState] = useState<BridgeState>('checking')
  const [devices, setDevices] = useState<Device[]>([])
  const [error, setError] = useState<string | null>(null)
  const [scanning, setScanning] = useState(false)
  const [attempts, setAttempts] = useState(0)
  // Ids with a command in flight, so the poll does not overwrite the
  // optimistic value with a stale reading mid-flight.
  const inFlight = useRef(new Set<string>())

  useEffect(() => {
    window.localStorage.setItem(PORT_KEY, String(port))
  }, [port])

  const poll = useCallback(async () => {
    try {
      const list = await fetchDevices(port)
      setDevices(previous =>
        list.map(device =>
          inFlight.current.has(device.id)
            ? (previous.find(p => p.id === device.id) ?? device)
            : device,
        ),
      )
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
    checkHealth(port)
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

  /** Apply an optimistic patch, send the command, then release the lock. */
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

  const scan = useCallback(async () => {
    setScanning(true)
    try {
      await startDiscovery(port)
      // Give devices a moment to answer the broadcast before re-reading.
      await new Promise(resolve => setTimeout(resolve, 1500))
      await poll()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setScanning(false)
    }
  }, [port, poll])

  if (state !== 'connected') {
    return (
      <BridgeSetup
        state={state}
        port={port}
        error={error}
        attempts={attempts}
        onPort={setPort}
        onRetry={connect}
      />
    )
  }

  const reachable = devices.filter(d => d.reachable)

  return (
    <div className="shell">
      <header className="bar">
        <div className="brand">
          <span className="dot" aria-hidden="true" />
          <h1>LumenDesk</h1>
        </div>
        <div className="bar-actions">
          <span className="status" role="status">
            {reachable.length} light{reachable.length === 1 ? '' : 's'} on this network
          </span>
          <button className="ghost" onClick={scan} disabled={scanning}>
            {scanning ? 'Scanning…' : 'Scan again'}
          </button>
        </div>
      </header>

      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}

      <main>
        {devices.length === 0 ? (
          <EmptyState scanning={scanning} onScan={scan} />
        ) : (
          <ul className="grid">
            {devices.map(device => (
              <LightCard key={device.id} device={device} port={port} run={run} />
            ))}
          </ul>
        )}
      </main>

      <footer className="foot">
        <span>Local control only · no account · no cloud</span>
        <span>Bridge on 127.0.0.1:{port}</span>
      </footer>
    </div>
  )
}

function LightCard({
  device,
  port,
  run,
}: {
  device: Device
  port: number
  run: (d: Device, patch: Partial<Device>, action: () => Promise<Device>) => Promise<void>
}) {
  const disabled = !device.reachable
  const hex = rgbToHex(device.color ?? { r: 255, g: 255, b: 255 })

  return (
    <li className={`card${device.power ? ' on' : ''}${disabled ? ' offline' : ''}`}>
      <div className="card-head">
        <div>
          <h2>{device.name}</h2>
          <p className="meta">
            <span className={`badge ${device.brand}`}>{device.brand.toUpperCase()}</span>
            <span>{device.ip ?? 'no address'}</span>
            {!device.reachable && <span className="warn">Offline</span>}
          </p>
        </div>
        <button
          className={`toggle${device.power ? ' active' : ''}`}
          onClick={() => run(device, { power: !device.power }, () => setPower(port, device.id, !device.power))}
          disabled={disabled}
          aria-pressed={device.power}
        >
          {device.power ? 'On' : 'Off'}
        </button>
      </div>

      <label className="field">
        <span>
          Brightness <strong>{device.brightness}%</strong>
        </span>
        <input
          type="range"
          min={0}
          max={100}
          value={device.brightness}
          disabled={disabled}
          onChange={event => {
            const value = Number(event.target.value)
            run(device, { brightness: value }, () => setBrightness(port, device.id, value))
          }}
        />
      </label>

      <div className="field">
        <span>Colour</span>
        <div className="swatches">
          {PRESETS.map(preset => (
            <button
              key={preset.label}
              className="swatch"
              style={{ background: rgbToHex(preset.rgb) }}
              title={preset.label}
              aria-label={preset.label}
              disabled={disabled}
              onClick={() => run(device, { color: preset.rgb }, () => setColor(port, device.id, preset.rgb))}
            />
          ))}
          <input
            type="color"
            className="picker"
            value={hex}
            disabled={disabled}
            aria-label="Custom colour"
            onChange={event => {
              const rgb = hexToRGB(event.target.value)
              run(device, { color: rgb }, () => setColor(port, device.id, rgb))
            }}
          />
        </div>
      </div>

      <div className="field">
        <span>White</span>
        <div className="whites">
          {[2700, 4000, 6500].map(k => (
            <button
              key={k}
              className="chip"
              disabled={disabled}
              onClick={() => run(device, { kelvin: k }, () => setKelvin(port, device.id, k))}
            >
              {k}K
            </button>
          ))}
        </div>
      </div>
    </li>
  )
}

function EmptyState({ scanning, onScan }: { scanning: boolean; onScan: () => void }) {
  return (
    <div className="panel">
      <h2>No lights found yet</h2>
      <p>
        The bridge is running but has not heard from any lights. LIFX bulbs answer automatically;
        Govee devices must have <strong>LAN Control</strong> enabled in the Govee Home app.
      </p>
      <button className="primary" onClick={onScan} disabled={scanning}>
        {scanning ? 'Scanning…' : 'Scan for lights'}
      </button>
    </div>
  )
}

function BridgeSetup({
  state,
  port,
  error,
  attempts,
  onPort,
  onRetry,
}: {
  state: BridgeState
  port: number
  error: string | null
  attempts: number
  onPort: (value: number) => void
  onRetry: () => void
}) {
  const checking = state === 'checking'
  return (
    <div className="shell centered">
      <div className="panel wide">
        <span className="eyebrow">Local control only</span>
        <h1>Start the LumenDesk bridge</h1>
        <p>
          Browsers cannot open the raw UDP sockets that LIFX and Govee lights speak, so a small
          helper runs on your machine and does it for you. This page talks only to that helper on
          <code> 127.0.0.1</code> — no account, no cloud, nothing leaves your network.
        </p>

        <ol className="steps">
          <li>
            Install <a href="https://nodejs.org/">Node.js 20 or newer</a>, if you do not have it.
            Check with <code>node --version</code>.
          </li>
          <li>
            Open a terminal and run these three commands:
            <pre>
              <code>{`git clone --depth 1 https://github.com/SeanPVera/LumenDesk.git
cd LumenDesk/web/bridge
npm start`}</code>
            </pre>
            <span className="note">
              No <code>npm install</code> needed — the bridge has no dependencies. It prints{' '}
              <code>listening on http://127.0.0.1:8765</code> when it is ready.
            </span>
          </li>
          <li>
            <strong>Leave that terminal open</strong> and come back here. The bridge only runs while
            the terminal does.
          </li>
        </ol>

        <details className="alt">
          <summary>No git installed?</summary>
          <p>Download and unpack the repository instead:</p>
          <pre>
            <code>{`curl -L https://github.com/SeanPVera/LumenDesk/archive/refs/heads/main.tar.gz | tar xz
cd LumenDesk-main/web/bridge
npm start`}</code>
          </pre>
        </details>

        <div className="setup-actions">
          <label className="port">
            Bridge port
            <input
              type="number"
              value={port}
              min={1}
              max={65535}
              disabled={checking}
              onChange={event => onPort(Number(event.target.value) || DEFAULT_PORT)}
            />
          </label>
          <button className="primary" onClick={onRetry} disabled={checking}>
            {checking ? 'Connecting…' : 'Connect'}
          </button>
        </div>

        {attempts > 0 && !checking && (
          <div className="diagnostic" role="alert">
            <p className="diagnostic-head">
              {error ?? 'Could not reach the bridge.'} Tried{' '}
              <code>{healthURL(port)}</code>
              {attempts > 1 && ` · ${attempts} attempts`}
            </p>

            <p>
              <strong>1. Check whether the bridge is running.</strong> Open{' '}
              <a href={healthURL(port)} target="_blank" rel="noreferrer">
                {healthURL(port)}
              </a>{' '}
              in a new tab.
            </p>
            <ul>
              <li>
                If that tab shows <code>{'{"ok":true,…}'}</code>, the bridge is fine and your
                browser is blocking this page from reaching it — see step 2.
              </li>
              <li>
                If the tab fails to load, the bridge is not running. Start it with the commands
                above, and check the port here matches the one it printed.
              </li>
            </ul>

            <p>
              <strong>2. Allow local network access.</strong> Chrome 142 and later ask permission
              before a website may reach your local network. Look for that prompt, or click the
              icon to the left of the address bar → <em>Site settings</em> → allow{' '}
              <em>Local network access</em>, then press Connect again.
            </p>

            <p>
              <strong>Still stuck?</strong> Run this page from your own machine instead — same
              bridge, no permission needed:
            </p>
            <pre>
              <code>{`cd LumenDesk/web/app
npm install
npm run dev`}</code>
            </pre>
          </div>
        )}
      </div>
    </div>
  )
}
