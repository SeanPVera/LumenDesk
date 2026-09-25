import { useState } from 'react'
import {
  type Device,
  type Room,
  type Scene,
  type Schedule,
  type ScheduleAction,
  hexToRGB,
  rgbToHex,
} from './bridge'
import { ShapesEditor, ShapesMiniWall, type ShapesActions } from './ShapesEditor'

export const ACTION_LABELS: Record<ScheduleAction, string> = {
  turnOn: 'Turn on',
  turnOff: 'Turn off',
  dim10: 'Dim to 10%',
  dim25: 'Dim to 25%',
  dim50: 'Dim to 50%',
  dim75: 'Dim to 75%',
  applyScene: 'Apply scene',
}

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

export const PRESETS = [
  { label: 'Warm', rgb: { r: 255, g: 176, b: 92 } },
  { label: 'Amber', rgb: { r: 231, g: 179, b: 90 } },
  { label: 'Cyan', rgb: { r: 115, g: 180, b: 189 } },
  { label: 'Green', rgb: { r: 131, g: 182, b: 122 } },
  { label: 'Copper', rgb: { r: 201, g: 120, b: 82 } },
  { label: 'Cool', rgb: { r: 220, g: 232, b: 255 } },
]

export interface Controls {
  power: (d: Device, on: boolean) => void
  brightness: (d: Device, value: number) => void
  color: (d: Device, rgb: { r: number; g: number; b: number }) => void
  kelvin: (d: Device, k: number) => void
  favorite: (d: Device) => void
  rename: (d: Device, name: string) => void
  assign: (d: Device, roomID: string | null) => void
  /** Panel-resolved commands for a paired Nanoleaf Shapes wall. */
  shapes: (d: Device) => ShapesActions
}

/** A Shapes wall whose layout the bridge has read, so its panels can be drawn. */
export const isShapesWall = (d: Device) => d.brand === 'nanoleaf' && Boolean(d.shapes?.geometry?.panels.length)

function outputKind(d: Device): string {
  if (isShapesWall(d)) return `Shapes · ${d.shapes!.geometry!.panels.length} panels`
  return d.brand === 'nanoleaf' ? 'Shapes · layout not read yet' : 'Whole-fixture color'
}

// MARK: light card

export function LightCard({
  device,
  controls,
  selectable,
  selected,
  onSelect,
  compact,
}: {
  device: Device
  controls: Controls
  selectable?: boolean
  selected?: boolean
  onSelect?: (id: string) => void
  compact?: boolean
}) {
  const disabled = !device.reachable
  const hex = rgbToHex(device.color ?? { r: 255, g: 255, b: 255 })

  return (
    <li className={`card${device.power ? ' on' : ''}${disabled ? ' offline' : ''}${selected ? ' selected' : ''}`}>
      <div className="card-head">
        <div className="card-title">
          {selectable && (
            <input
              type="checkbox"
              checked={Boolean(selected)}
              aria-label={`Select ${device.name}`}
              onChange={() => onSelect?.(device.id)}
            />
          )}
          <div>
            <h2>{device.name}</h2>
            <p className="meta">
              <span className={`badge ${device.brand}`}>{device.brand.toUpperCase()}</span>
              <span>{device.ip ?? 'no address'}</span>
              {!device.reachable && <span className="warn">Offline</span>}
            </p>
          </div>
        </div>
        <div className="card-actions">
          <button
            className={`star${device.favorite ? ' active' : ''}`}
            onClick={() => controls.favorite(device)}
            aria-pressed={Boolean(device.favorite)}
            title={device.favorite ? 'Remove from favourites' : 'Add to favourites'}
          >
            {device.favorite ? '★' : '☆'}
          </button>
          <button
            className={`toggle${device.power ? ' active' : ''}`}
            onClick={() => controls.power(device, !device.power)}
            disabled={disabled}
            aria-pressed={device.power}
          >
            {device.power ? 'On' : 'Off'}
          </button>
        </div>
      </div>

      {!compact && (
        <>
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
              onChange={e => controls.brightness(device, Number(e.target.value))}
            />
          </label>

          <div className="field">
            <span>Colour</span>
            <div className="swatches">
              {PRESETS.map(p => (
                <button
                  key={p.label}
                  className="swatch"
                  style={{ background: rgbToHex(p.rgb) }}
                  title={p.label}
                  aria-label={p.label}
                  disabled={disabled}
                  onClick={() => controls.color(device, p.rgb)}
                />
              ))}
              <input
                type="color"
                className="picker"
                value={hex}
                disabled={disabled}
                aria-label="Custom colour"
                onChange={e => controls.color(device, hexToRGB(e.target.value))}
              />
            </div>
          </div>

          <div className="field">
            <span>White</span>
            <div className="whites">
              {[2700, 4000, 6500].map(k => (
                <button key={k} className="chip" disabled={disabled} onClick={() => controls.kelvin(device, k)}>
                  {k}K
                </button>
              ))}
            </div>
          </div>
        </>
      )}
    </li>
  )
}

// MARK: Home

export function HomeView({ devices, controls, onBulk, onScan, scanning }: {
  devices: Device[]; rooms: Room[]; controls: Controls
  onBulk: (ids: string[], action: 'on' | 'off') => void
  onScan: () => void; scanning: boolean
}) {
  const [selected, setSelected] = useState<string[]>([])
  const [query, setQuery] = useState('')
  const visible = devices.filter(d => d.name.toLowerCase().includes(query.trim().toLowerCase()))
  const active = selected.filter(id => devices.some(d => d.id === id))
  const targets = (selected.length ? devices.filter(d => active.includes(d.id)) : devices).filter(d => d.reachable)
  const level = targets.length ? Math.round(targets.reduce((sum, d) => sum + d.brightness, 0) / targets.length) : 0
  const toggle = (id: string) => setSelected(ids => ids.includes(id) ? ids.filter(x => x !== id) : [...ids, id])
  const color = rgbToHex(targets[0]?.color ?? {r: 255, g: 255, b: 255})
  const mixed = new Set(targets.map(d => rgbToHex(d.color ?? {r: 255, g: 255, b: 255}))).size > 1
  return <section className="room-workspace" aria-label="Room lighting">
    {!devices.length ? <EmptyLights scanning={scanning} onScan={onScan} /> : <>
      <div className="light-field" aria-label="Fixtures in this room">
        <p className="field-caption">Fixture order · select to control{devices.length > 12 && ' · scroll for more fixtures'}</p>
        <div className="emitters">
          {devices.map(d => <button key={d.id} className="emitter"
            title={d.name} aria-pressed={active.includes(d.id)} onClick={() => toggle(d.id)}
            aria-label={`${d.name}, ${!d.reachable ? 'not responding' : d.power ? `${d.brightness}% on` : 'off'}`}>
            {isShapesWall(d) ? <ShapesMiniWall device={d} /> : <span className="emission" style={{
              background: d.power && d.reachable ? rgbToHex(d.color ?? {r: 255,g:255,b:255}) : 'var(--surface)',
              opacity: d.power && d.reachable ? 0.25 + d.brightness / 135 : 1,
            }} aria-hidden="true" />}
            <strong>{d.name}</strong>
            <span>{!d.reachable ? 'Not responding' : d.power ? `${d.brightness}% · On` : 'Off'}</span>
            <span className="selection-mark" aria-hidden="true">{active.includes(d.id) ? '✓' : '+'}</span>
          </button>)}
        </div>
        <p className="note">Fixture order, not room positions. Shapes walls are drawn panel by panel; other fixtures show one colour.</p>
      </div>
      <div className="room-editing">
        <div className="fixture-directory">
          <div className="section-line"><h2>Fixtures</h2><button onClick={() => setSelected(visible.map(d => d.id))}>Select visible</button></div>
          <input type="search" aria-label="Find a fixture" placeholder="Find a fixture" value={query} onChange={e => setQuery(e.target.value)} />
          {active.some(id => !visible.some(d => d.id === id)) && <p className="note">Your selection includes fixtures hidden by this search.</p>}
          <ul className="fixture-rows">{visible.map(d => <li key={d.id}>
            <label><input type="checkbox" checked={active.includes(d.id)} onChange={() => toggle(d.id)} />
              <span><strong>{d.name}</strong><small>{d.brand.toUpperCase()} · {outputKind(d)}</small></span>
            </label>
            <span>{!d.reachable ? 'Offline' : d.power ? `${d.brightness}%` : 'Off'}</span>
          </li>)}</ul>
          {!visible.length && <p>No fixtures match this search.</p>}
        </div>
        <section className="output-controls" aria-label="Selected output controls">
          <div className="section-line"><h2>{selected.length ? `${active.length} selected` : 'Room output'}</h2>
            {selected.length > 0 && <button onClick={() => setSelected([])}>Clear</button>}</div>
          <p className="meta">{targets.length} available · changes apply to {selected.length ? 'your selection' : 'this room'}</p>
          <div className="toolbar">
            <button className="primary" disabled={!targets.length} onClick={() => onBulk(targets.map(d => d.id), 'on')}>On</button>
            <button disabled={!targets.length} onClick={() => onBulk(targets.map(d => d.id), 'off')}>Off</button>
          </div>
          <label className="field" htmlFor="room-brightness">Brightness <output>{level}%</output>
            <input id="room-brightness" type="range" min="0" max="100" value={level} disabled={!targets.length}
              onChange={e => targets.forEach(d => controls.brightness(d, Number(e.target.value)))} />
          </label>
          <label className="color-control">Color
            <input type="color" value={color} disabled={!targets.length}
              onChange={e => targets.forEach(d => controls.color(d, hexToRGB(e.target.value)))} />
            <span>{mixed ? 'Mixed' : color.toUpperCase()}</span>
          </label>
          <label className="field" htmlFor="room-white">White temperature <output>{targets[0]?.kelvin ?? 3500} K</output>
            <input id="room-white" type="range" min="2500" max="9000" step="100" value={targets[0]?.kelvin ?? 3500} disabled={!targets.length}
              onChange={e => targets.forEach(d => controls.kelvin(d, Number(e.target.value)))} />
          </label>
          <p className="note">Color and white replace the current whole-fixture output, a Shapes design or scene included. Hardware limits still apply.</p>
          {active.length !== 1 && targets.some(isShapesWall) && <p className="note">Select one Shapes wall on its own to paint its panels.</p>}
          {active.length === 1 && <details><summary>Fixture details</summary>
            <ul className="inspector-list"><LightCard device={devices.find(d => d.id === active[0])!} controls={controls} compact /></ul>
          </details>}
        </section>
      </div>
      {active.length === 1 && (() => {
        const wall = devices.find(d => d.id === active[0])
        return wall && isShapesWall(wall) ? <ShapesEditor key={wall.id} device={wall} actions={controls.shapes(wall)} /> : null
      })()}
    </>}
  </section>
}

function Group({ title, count, children }: { title: string; count?: number; children: React.ReactNode }) {
  return (
    <div className="group">
      <h2 className="group-title">
        {title}
        {count !== undefined && <span className="count">{count}</span>}
      </h2>
      {children}
    </div>
  )
}

function EmptyLights({ scanning, onScan }: { scanning: boolean; onScan: () => void }) {
  return (
    <div className="panel">
      <h2>No lights found yet</h2>
      <p>
        The bridge is running but has not heard from any lights. LIFX bulbs answer automatically;
        Govee devices must have <strong>LAN Control</strong> enabled in the Govee Home app. Nanoleaf
        Shapes walls are paired once from <strong>Devices</strong>.
      </p>
      <button className="primary" onClick={onScan} disabled={scanning}>
        {scanning ? 'Scanning…' : 'Scan for lights'}
      </button>
    </div>
  )
}

// MARK: Library (scenes)

export function LibraryView({
  scenes,
  devices,
  onSave,
  onApply,
  onDelete,
}: {
  scenes: Scene[]
  devices: Device[]
  onSave: (name: string) => void
  onApply: (scene: Scene) => void
  onDelete: (scene: Scene) => void
}) {
  const [name, setName] = useState('')

  return (
    <section>
      <div className="panel">
        <h2>Save the current lighting</h2>
        <p>
          Captures this room's power, brightness and colour right now, so you can bring it back
          in one click. {devices.length} light{devices.length === 1 ? '' : 's'} will be included.
        </p>
        <form
          className="inline-form"
          onSubmit={e => {
            e.preventDefault()
            if (!name.trim()) return
            onSave(name.trim())
            setName('')
          }}
        >
          <input
            type="text"
            placeholder="Scene name, e.g. Evening"
            value={name}
            onChange={e => setName(e.target.value)}
            maxLength={60}
          />
          <button className="primary" type="submit" disabled={!name.trim() || devices.length === 0}>
            Save scene
          </button>
        </form>
      </div>

      {scenes.length === 0 ? (
        <p className="empty">No scenes saved yet.</p>
      ) : (
        <ul className="composition-list">
          {scenes.map(scene => (
            <li key={scene.id} className="composition">
              <div className="card-head">
                <div>
                  <h2>{scene.name}</h2>
                  <p className="meta">
                    <span>{Object.keys(scene.snapshots ?? {}).length} lights</span>
                    <span>{new Date(scene.createdAt).toLocaleDateString()}</span>
                  </p>
                </div>
              </div>
              <SceneScore scene={scene} />
              <p className="note">Recalls its saved fixtures, including any outside the current room.</p>
              <div className="whites">
                <button className="primary" onClick={() => onApply(scene)}>
                  Apply
                </button>
                <button className="ghost" onClick={() => { if (window.confirm(`Delete “${scene.name}”? This cannot be undone in the browser.`)) onDelete(scene) }}>
                  Delete
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function SceneScore({ scene }: { scene: Scene }) {
  return <div className="scene-score" aria-label="Saved fixture color and level">
    {Object.keys(scene.snapshots ?? {}).sort().map(id => {
      const s = scene.snapshots[id] as { power?: boolean; brightness?: number; color?: {r:number;g:number;b:number} }
      return <span key={id} style={{
        background: s.color ? rgbToHex(s.color) : 'var(--secondary)',
        height: s.power === false ? 3 : 8 + Math.max(0, Math.min(100, s.brightness ?? 50)) * 0.3,
        opacity: s.power === false ? 0.25 : 1,
      }} />
    })}
  </div>
}

// MARK: Automation (schedules)

export function AutomationView({
  rooms,
  scenes,
  onAdd,
  onUpdate,
  onDelete,
}: {
  rooms: Room[]
  scenes: Scene[]
  onAdd: (roomID: string, entry: Partial<Schedule>) => void
  onUpdate: (roomID: string, scheduleID: string, patch: Partial<Schedule>) => void
  onDelete: (roomID: string, scheduleID: string) => void
}) {
  if (rooms.length === 0) {
    return (
      <div className="panel">
        <h2>Create a room first</h2>
        <p>
          Schedules act on a room's lights, so add a room in <strong>Devices</strong> and assign
          some lights to it.
        </p>
      </div>
    )
  }

  return (
    <section>
      <p className="note wide-note">
        Schedules run in the bridge, so they fire whether or not this page is open — as long as the
        bridge is running.
      </p>
      {rooms.map(room => (
        <div className="group" key={room.id}>
          <h2 className="group-title">
            {room.name}
            <span className="count">{room.schedules.length}</span>
          </h2>
          <ul className="rows">
            {room.schedules.map(s => (
              <li key={s.id} className={`row${s.isEnabled ? '' : ' muted'}`}>
                <label className="row-toggle">
                  <input
                    type="checkbox"
                    checked={s.isEnabled}
                    onChange={e => onUpdate(room.id, s.id, { isEnabled: e.target.checked })}
                    aria-label={`Enable ${ACTION_LABELS[s.action]}`}
                  />
                </label>
                <strong className="row-time">
                  {String(s.hour).padStart(2, '0')}:{String(s.minute).padStart(2, '0')}
                </strong>
                <span className="row-action">
                  {ACTION_LABELS[s.action]}
                  {s.action === 'applyScene' &&
                    ` — ${scenes.find(x => x.id === s.sceneID)?.name ?? 'missing scene'}`}
                </span>
                <span className="row-days">
                  {s.weekdays.length === 7 ? 'Every day' : s.weekdays.map(d => DAYS[d - 1]).join(' ')}
                </span>
                <button className="ghost" onClick={() => onDelete(room.id, s.id)}>
                  Delete
                </button>
              </li>
            ))}
          </ul>
          <ScheduleForm room={room} scenes={scenes} onAdd={onAdd} />
        </div>
      ))}
    </section>
  )
}

function ScheduleForm({
  room,
  scenes,
  onAdd,
}: {
  room: Room
  scenes: Scene[]
  onAdd: (roomID: string, entry: Partial<Schedule>) => void
}) {
  const [time, setTime] = useState('07:30')
  const [action, setAction] = useState<ScheduleAction>('turnOn')
  const [sceneID, setSceneID] = useState('')
  const [weekdays, setWeekdays] = useState<number[]>([1, 2, 3, 4, 5, 6, 7])

  const toggleDay = (day: number) =>
    setWeekdays(days => (days.includes(day) ? days.filter(d => d !== day) : [...days, day].sort()))

  return (
    <form
      className="inline-form"
      onSubmit={e => {
        e.preventDefault()
        const [hour, minute] = time.split(':').map(Number)
        onAdd(room.id, {
          hour,
          minute,
          action,
          weekdays,
          sceneID: action === 'applyScene' ? sceneID || null : null,
        })
      }}
    >
      <input type="time" value={time} onChange={e => setTime(e.target.value)} required />
      <select value={action} onChange={e => setAction(e.target.value as ScheduleAction)}>
        {(Object.keys(ACTION_LABELS) as ScheduleAction[]).map(a => (
          <option key={a} value={a}>
            {ACTION_LABELS[a]}
          </option>
        ))}
      </select>
      {action === 'applyScene' && (
        <select value={sceneID} onChange={e => setSceneID(e.target.value)} required>
          <option value="">Choose a scene…</option>
          {scenes.map(s => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
      )}
      <div className="days" role="group" aria-label="Days">
        {DAYS.map((label, index) => {
          const day = index + 1
          return (
            <button
              key={label}
              type="button"
              className={`chip day${weekdays.includes(day) ? ' active' : ''}`}
              aria-pressed={weekdays.includes(day)}
              onClick={() => toggleDay(day)}
            >
              {label}
            </button>
          )
        })}
      </div>
      <button
        type="submit"
        disabled={(action === 'applyScene' && !sceneID) || weekdays.length === 0}
      >
        Add schedule
      </button>
    </form>
  )
}

// MARK: Devices

function ShapesPairing({ onPair }: { onPair: (host: string, port: number) => Promise<void> }) {
  const [host, setHost] = useState('')
  const [port, setPort] = useState('16021')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  return (
    <div className="panel">
      <h2>Pair a Nanoleaf Shapes wall</h2>
      <ol className="steps">
        <li>Find the controller’s IP address in your router’s list of connected devices.</li>
        <li>Hold the controller’s power button for 5–7 seconds, until its LED flashes.</li>
        <li>Within 30 seconds, enter the address and choose Pair.</li>
      </ol>
      <form
        className="schedule-form"
        onSubmit={async e => {
          e.preventDefault()
          setBusy(true)
          setProblem(null)
          try {
            await onPair(host.trim(), Number(port) || 16021)
            setHost('')
          } catch (err) {
            setProblem(err instanceof Error ? err.message : String(err))
          } finally {
            setBusy(false)
          }
        }}
      >
        <label>Controller address
          <input type="text" inputMode="decimal" placeholder="192.168.1.40" value={host}
            onChange={e => setHost(e.target.value)} autoComplete="off" spellCheck={false} />
        </label>
        <label>Port
          <input type="number" min={1} max={65535} value={port} onChange={e => setPort(e.target.value)} />
        </label>
        <button className="primary" type="submit" disabled={busy || !host.trim()}>{busy ? 'Pairing…' : 'Pair'}</button>
      </form>
      {problem && <p className="error" role="alert">{problem}</p>}
      <p className="note">
        The bridge keeps the controller’s access token in <code>~/.lumendesk/nanoleaf-pairings.json</code>,
        readable only by your user account. The token never reaches this page.
      </p>
    </div>
  )
}

export function DevicesView({
  devices,
  rooms,
  controls,
  onAddRoom,
  onDeleteRoom,
  onPairShapes,
  onForgetShapes,
  onScan,
  scanning,
}: {
  devices: Device[]
  rooms: Room[]
  controls: Controls
  onAddRoom: (name: string) => void
  onDeleteRoom: (room: Room) => void
  onPairShapes: (host: string, port: number) => Promise<void>
  onForgetShapes: (d: Device) => void
  onScan: () => void
  scanning: boolean
}) {
  const [roomName, setRoomName] = useState('')

  return (
    <section>
      <div className="panel">
        <h2>Rooms</h2>
        <p>Group lights so scenes and schedules can act on them together.</p>
        <form
          className="inline-form"
          onSubmit={e => {
            e.preventDefault()
            if (!roomName.trim()) return
            onAddRoom(roomName.trim())
            setRoomName('')
          }}
        >
          <input
            type="text"
            placeholder="Room name, e.g. Studio"
            value={roomName}
            onChange={e => setRoomName(e.target.value)}
            maxLength={60}
          />
          <button className="primary" type="submit" disabled={!roomName.trim()}>
            Add room
          </button>
        </form>
        {rooms.length > 0 && (
          <ul className="pills">
            {rooms.map(r => (
              <li key={r.id} className="pill">
                {r.name} <span className="count">{r.lightIDs.length}</span>
                <button className="pill-x" onClick={() => onDeleteRoom(r)} aria-label={`Delete ${r.name}`}>
                  ×
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <ShapesPairing onPair={onPairShapes} />

      <div className="group">
        <h2 className="group-title">
          Discovered lights
          <span className="count">{devices.length}</span>
          <button className="ghost" onClick={onScan} disabled={scanning}>
            {scanning ? 'Scanning…' : 'Scan again'}
          </button>
        </h2>
        {devices.length === 0 ? (
          <p className="empty">Nothing discovered yet.</p>
        ) : (
          <ul className="rows">
            {devices.map(d => (
              <li key={d.id} className={`row${d.reachable ? '' : ' muted'}`}>
                <span className={`badge ${d.brand}`}>{d.brand.toUpperCase()}</span>
                <input
                  className="rename"
                  defaultValue={d.name}
                  aria-label={`Rename ${d.name}`}
                  onBlur={e => {
                    const value = e.target.value.trim()
                    if (value && value !== d.name) controls.rename(d, value)
                  }}
                />
                <span className="row-days mono">{d.ip ?? '—'}</span>
                <select
                  value={d.roomID ?? ''}
                  onChange={e => controls.assign(d, e.target.value || null)}
                  aria-label={`Room for ${d.name}`}
                >
                  <option value="">No room</option>
                  {rooms.map(r => (
                    <option key={r.id} value={r.id}>
                      {r.name}
                    </option>
                  ))}
                </select>
                <span className={d.reachable && !d.needsPairing ? 'ok' : 'warn'}>
                  {d.needsPairing ? 'Pair again' : d.reachable ? 'Online' : 'Offline'}
                </span>
                {d.brand === 'nanoleaf' && (
                  <button className="ghost" aria-label={`Forget ${d.name}`} onClick={() => {
                    if (window.confirm(`Forget “${d.name}”? The bridge deletes its access token; pairing again needs the power button.`)) onForgetShapes(d)
                  }}>Forget</button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}

// MARK: Settings

export function SettingsView({
  port,
  servedByBridge,
  deviceCount,
  onScan,
  scanning,
}: {
  port: number
  servedByBridge: boolean
  deviceCount: number
  onScan: () => void
  scanning: boolean
}) {
  return (
    <section>
      <div className="panel">
        <h2>Bridge</h2>
        <ul className="rows">
          <li className="row">
            <span className="row-action">Address</span>
            <span className="mono">
              {servedByBridge ? window.location.origin : `http://127.0.0.1:${port}`}
            </span>
          </li>
          <li className="row">
            <span className="row-action">Connection</span>
            <span>{servedByBridge ? 'Served by the bridge (same origin)' : 'Cross-origin to loopback'}</span>
          </li>
          <li className="row">
            <span className="row-action">Lights known</span>
            <span>{deviceCount}</span>
          </li>
        </ul>
        <button className="ghost" onClick={onScan} disabled={scanning}>
          {scanning ? 'Scanning…' : 'Rescan the network'}
        </button>
      </div>

      <div className="panel">
        <h2>Privacy</h2>
        <p>
          Everything stays on this machine. The bridge talks to your lights over your own network
          and there is no account, no cloud service and no telemetry. Rooms, scenes and schedules
          are stored in <code>~/.lumendesk/bridge-state.json</code>.
        </p>
      </div>

      <div className="panel">
        <h2>Not here yet</h2>
        <p>
          Animated effects, Govee RGBIC segment editing, LIFX matrix control and panel-by-panel
          Shapes music are native-app features. In the browser, Music Mode drives every fixture,
          Shapes walls included, as one colour.
        </p>
      </div>
    </section>
  )
}
