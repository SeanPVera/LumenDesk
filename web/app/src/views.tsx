import { useMemo, useState } from 'react'
import {
  type Device,
  type Room,
  type Scene,
  type Schedule,
  type ScheduleAction,
  hexToRGB,
  rgbToHex,
} from './bridge'

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

export function HomeView({
  devices,
  rooms,
  controls,
  onBulk,
  onScan,
  scanning,
}: {
  devices: Device[]
  rooms: Room[]
  controls: Controls
  onBulk: (ids: string[], action: 'on' | 'off') => void
  onScan: () => void
  scanning: boolean
}) {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<'all' | 'on' | 'off' | 'favorites' | 'offline'>('all')
  const [selected, setSelected] = useState<string[]>([])

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase()
    return devices.filter(d => {
      if (q && !d.name.toLowerCase().includes(q) && !(d.ip ?? '').includes(q)) return false
      if (filter === 'on') return d.power
      if (filter === 'off') return !d.power
      if (filter === 'favorites') return d.favorite
      if (filter === 'offline') return !d.reachable
      return true
    })
  }, [devices, query, filter])

  const favorites = visible.filter(d => d.favorite)
  const grouped = rooms
    .map(room => ({ room, lights: visible.filter(d => room.lightIDs.includes(d.id)) }))
    .filter(g => g.lights.length > 0)
  const unassigned = visible.filter(d => !d.roomID)

  const toggleSelect = (id: string) =>
    setSelected(s => (s.includes(id) ? s.filter(x => x !== id) : [...s, id]))

  return (
    <section>
      <div className="toolbar">
        <input
          className="search"
          type="search"
          placeholder="Search lights…"
          value={query}
          onChange={e => setQuery(e.target.value)}
        />
        <div className="filters" role="group" aria-label="Filter lights">
          {(['all', 'on', 'off', 'favorites', 'offline'] as const).map(f => (
            <button
              key={f}
              className={`chip${filter === f ? ' active' : ''}`}
              onClick={() => setFilter(f)}
            >
              {f === 'all' ? 'All' : f[0].toUpperCase() + f.slice(1)}
            </button>
          ))}
        </div>
        <button className="ghost" onClick={onScan} disabled={scanning}>
          {scanning ? 'Scanning…' : 'Scan again'}
        </button>
      </div>

      {selected.length > 0 && (
        <div className="bulk" role="region" aria-label="Bulk actions">
          <span>
            <strong>{selected.length}</strong> selected
          </span>
          <button onClick={() => onBulk(selected, 'on')}>All on</button>
          <button onClick={() => onBulk(selected, 'off')}>All off</button>
          <button className="ghost" onClick={() => setSelected([])}>
            Clear
          </button>
        </div>
      )}

      {devices.length === 0 ? (
        <EmptyLights scanning={scanning} onScan={onScan} />
      ) : visible.length === 0 ? (
        <p className="empty">No lights match that search.</p>
      ) : (
        <>
          {favorites.length > 0 && filter !== 'favorites' && (
            <Group title="Favourites">
              <ul className="grid">
                {favorites.map(d => (
                  <LightCard key={d.id} device={d} controls={controls} compact />
                ))}
              </ul>
            </Group>
          )}

          {grouped.map(({ room, lights }) => (
            <Group key={room.id} title={room.name} count={lights.length}>
              <div className="group-actions">
                <button className="chip" onClick={() => onBulk(lights.map(l => l.id), 'on')}>
                  Room on
                </button>
                <button className="chip" onClick={() => onBulk(lights.map(l => l.id), 'off')}>
                  Room off
                </button>
              </div>
              <ul className="grid">
                {lights.map(d => (
                  <LightCard
                    key={d.id}
                    device={d}
                    controls={controls}
                    selectable
                    selected={selected.includes(d.id)}
                    onSelect={toggleSelect}
                  />
                ))}
              </ul>
            </Group>
          ))}

          {unassigned.length > 0 && (
            <Group title={grouped.length ? 'Unassigned' : 'All lights'} count={unassigned.length}>
              <ul className="grid">
                {unassigned.map(d => (
                  <LightCard
                    key={d.id}
                    device={d}
                    controls={controls}
                    selectable
                    selected={selected.includes(d.id)}
                    onSelect={toggleSelect}
                  />
                ))}
              </ul>
            </Group>
          )}
        </>
      )}
    </section>
  )
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
        Govee devices must have <strong>LAN Control</strong> enabled in the Govee Home app.
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
          Captures every light's power, brightness and colour right now, so you can bring it back
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
        <ul className="grid">
          {scenes.map(scene => (
            <li key={scene.id} className="card">
              <div className="card-head">
                <div>
                  <h2>{scene.name}</h2>
                  <p className="meta">
                    <span>{Object.keys(scene.snapshots ?? {}).length} lights</span>
                    <span>{new Date(scene.createdAt).toLocaleDateString()}</span>
                  </p>
                </div>
              </div>
              <div className="whites">
                <button className="primary" onClick={() => onApply(scene)}>
                  Apply
                </button>
                <button className="ghost" onClick={() => onDelete(scene)}>
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
      <button type="submit" disabled={action === 'applyScene' && !sceneID}>
        Add schedule
      </button>
    </form>
  )
}

// MARK: Devices

export function DevicesView({
  devices,
  rooms,
  controls,
  onAddRoom,
  onDeleteRoom,
  onScan,
  scanning,
}: {
  devices: Device[]
  rooms: Room[]
  controls: Controls
  onAddRoom: (name: string) => void
  onDeleteRoom: (room: Room) => void
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
                <span className={d.reachable ? 'ok' : 'warn'}>{d.reachable ? 'Online' : 'Offline'}</span>
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
          Animated effects, Music Mode, Govee RGBIC segment editing and LIFX matrix control are
          native-app features and are not part of the web client.
        </p>
      </div>
    </section>
  )
}
