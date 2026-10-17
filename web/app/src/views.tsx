import { useEffect, useState } from 'react'
import {
  type Device,
  type Room,
  type Scene,
  type RGB,
  hexToRGB,
  rgbToHex,
} from './bridge'
import { toTone } from './shapes/tone'
import { ShapesEditor, ShapesMiniWall, wallProductName, type ShapesActions } from './ShapesEditor'
import { SceneCapture } from './SceneCapture'
import { DeviceName } from './DeviceName'

export { AutomationView, ACTION_LABELS } from './SchedulesView'

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
  rename: (d: Device, name: string) => Promise<boolean>
  assign: (d: Device, roomID: string | null) => void
  /** Panel-resolved commands for a paired Nanoleaf Shapes or Aurora wall. */
  shapes: (d: Device) => ShapesActions
}

/** A Nanoleaf wall whose layout the bridge has read, so its panels can be drawn. */
export const isShapesWall = (d: Device) => d.brand === 'nanoleaf' && Boolean(d.shapes?.geometry?.panels.length)

function outputKind(d: Device): string {
  if (isShapesWall(d)) return `${wallProductName(d)} · ${d.shapes!.geometry!.panels.length} panels`
  return d.brand === 'nanoleaf' ? `${wallProductName(d)} · layout not read yet` : 'Whole-fixture color'
}

// MARK: light card

export function LightCard({
  device,
  controls,
  selectable,
  selected,
  onSelect,
  compact,
  showFavorite = true,
}: {
  device: Device
  controls: Controls
  selectable?: boolean
  selected?: boolean
  onSelect?: (id: string) => void
  compact?: boolean
  showFavorite?: boolean
}) {
  const disabled = !device.reachable || Boolean(device.needsPairing)
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
          {showFavorite && <button
            className={`star${device.favorite ? ' active' : ''}`}
            onClick={() => controls.favorite(device)}
            aria-pressed={Boolean(device.favorite)}
            aria-label={`${device.favorite ? 'Remove' : 'Add'} ${device.name} ${device.favorite ? 'from' : 'to'} favorites`}
            title={device.favorite ? 'Remove from favorites' : 'Add to favorites'}
          >
            {device.favorite ? '★' : '☆'}
          </button>}
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

export function HomeView({ devices, controls, onBulk, onScan, scanning, scopeName, onSaveScene, onSetupRoom, supportsSavedLighting = true }: {
  devices: Device[]; rooms: Room[]; controls: Controls
  onBulk: (ids: string[], action: 'on' | 'off') => void
  onScan: () => void; scanning: boolean
  scopeName: string
  onSaveScene: (name: string) => Promise<boolean>
  onSetupRoom?: () => void
  supportsSavedLighting?: boolean
}) {
  const [selected, setSelected] = useState<string[]>([])
  const [query, setQuery] = useState('')
  const [favoritesOnly, setFavoritesOnly] = useState(false)
  const showingFavorites = supportsSavedLighting && favoritesOnly
  const visible = devices.filter(d => (!showingFavorites || d.favorite) && d.name.toLowerCase().includes(query.trim().toLowerCase()))
  const inScopeSelection = selected.filter(id => devices.some(d => d.id === id))
  const active = inScopeSelection.filter(id => visible.some(d => d.id === id))
  const hiddenSelectionCount = inScopeSelection.length - active.length
  const filtered = showingFavorites || Boolean(query.trim())
  const targets = (inScopeSelection.length ? visible.filter(d => active.includes(d.id)) : visible).filter(d => d.reachable && !d.needsPairing)
  const level = targets.length ? Math.round(targets.reduce((sum, d) => sum + d.brightness, 0) / targets.length) : 0
  const mixedLevel = new Set(targets.map(d => d.brightness)).size > 1
  const white = targets[0]?.kelvin ?? 3500
  const knownWhite = targets.length > 0 && targets.every(d => d.kelvin != null)
  const mixedWhite = new Set(targets.map(d => d.kelvin)).size > 1
  const whiteLabel = !targets.length ? '—' : !knownWhite ? (mixedWhite ? 'Mixed / unknown' : 'Unknown') : mixedWhite ? 'Mixed' : `${white} K`
  const toggle = (id: string) => setSelected(ids => ids.includes(id) ? ids.filter(x => x !== id) : [...ids, id])
  const color = rgbToHex(targets[0]?.color ?? {r: 255, g: 255, b: 255})
  const mixed = new Set(targets.map(d => rgbToHex(d.color ?? {r: 255, g: 255, b: 255}))).size > 1
  return <section className="room-workspace" aria-label="Room lighting">
    {!devices.length ? <EmptyLights scanning={scanning} onScan={onScan} onSetupRoom={onSetupRoom} /> : <>
      {supportsSavedLighting && <div className="filters" role="group" aria-label="Fixture filters">
        <button className={`chip${favoritesOnly ? '' : ' active'}`} aria-pressed={!favoritesOnly}
          onClick={() => setFavoritesOnly(false)}>All fixtures ({devices.length})</button>
        <button className={`chip${favoritesOnly ? ' active' : ''}`} aria-pressed={favoritesOnly}
          onClick={() => setFavoritesOnly(true)}>★ Favorites ({devices.filter(d => d.favorite).length})</button>
      </div>}
      <input className="fixture-search" type="search" aria-label="Find a fixture" placeholder="Find a fixture" value={query} onChange={e => setQuery(e.target.value)} />
      <div className="light-field" aria-label="Fixtures in this room">
        <p className="field-caption">Fixture order · select to control{visible.length > 12 && ' · scroll for more fixtures'}</p>
        <div className="emitters">
          {visible.map(d => <button key={d.id} className="emitter"
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
        <p className="note">Fixture order, not room positions. Nanoleaf walls are drawn panel by panel; other fixtures show one colour.</p>
      </div>
      <div className="room-editing">
        <div className="fixture-directory">
          <div className="section-line"><h2>Fixtures</h2><button disabled={!visible.length} onClick={() => setSelected(visible.map(d => d.id))}>Select visible</button></div>
          {hiddenSelectionCount > 0 && <p className="note">{hiddenSelectionCount} selected fixture{hiddenSelectionCount === 1 ? ' is' : 's are'} hidden by your filters and excluded from changes.</p>}
          <ul className="fixture-rows">{visible.map(d => <li key={d.id}>
            <label><input type="checkbox" checked={active.includes(d.id)} onChange={() => toggle(d.id)} />
              <span><strong>{d.name}</strong><small>{d.brand.toUpperCase()} · {outputKind(d)}</small></span>
            </label>
            <span>{!d.reachable ? 'Offline' : d.power ? `${d.brightness}%` : 'Off'}</span>
            {supportsSavedLighting && <button className={`star${d.favorite ? ' active' : ''}`} onClick={() => controls.favorite(d)}
              aria-pressed={Boolean(d.favorite)}
              aria-label={`${d.favorite ? 'Remove' : 'Add'} ${d.name} ${d.favorite ? 'from' : 'to'} favorites`}
              title={d.favorite ? 'Remove from favorites' : 'Add to favorites'}>{d.favorite ? '★' : '☆'}</button>}
          </li>)}</ul>
          {!visible.length && <p>{showingFavorites && !devices.some(d => d.favorite)
            ? 'No favorites in this room yet. Choose All fixtures, then use a star beside a fixture.'
            : 'No fixtures match your filters.'}</p>}
        </div>
        <section className="output-controls" aria-label="Selected output controls">
          <div className="section-line"><h2>{inScopeSelection.length ? `${active.length} selected` : filtered ? 'Filtered output' : 'Room output'}</h2>
            {inScopeSelection.length > 0 && <button onClick={() => setSelected([])}>Clear</button>}</div>
          <p className="meta">{targets.length} available · changes apply to {inScopeSelection.length ? 'your visible selection' : filtered ? 'visible fixtures only' : scopeName}</p>
          <div className="toolbar">
            <button className="primary" disabled={!targets.length} onClick={() => onBulk(targets.map(d => d.id), 'on')}>On</button>
            <button disabled={!targets.length} onClick={() => onBulk(targets.map(d => d.id), 'off')}>Off</button>
          </div>
          <label className="field" htmlFor="room-brightness">Brightness <output>{mixedLevel ? `Mixed · ${level}% average` : `${level}%`}</output>
            <input id="room-brightness" type="range" min="0" max="100" value={level} disabled={!targets.length}
              aria-valuetext={mixedLevel ? `Mixed levels, averaging ${level} percent. Changing this sets all available fixtures.` : undefined}
              onChange={e => targets.forEach(d => controls.brightness(d, Number(e.target.value)))} />
          </label>
          <label className="color-control">Color
            <input type="color" value={color} disabled={!targets.length}
              onChange={e => targets.forEach(d => controls.color(d, hexToRGB(e.target.value)))} />
            <span>{mixed ? 'Mixed' : color.toUpperCase()}</span>
          </label>
          <label className="field" htmlFor="room-white">White temperature <output>{whiteLabel}</output>
            <input id="room-white" type="range" min="2500" max="9000" step="100" value={white} disabled={!targets.length}
              aria-valuetext={mixedWhite || !knownWhite ? `${whiteLabel}; slider starts at ${white} kelvin. Changing this sets all available fixtures.` : undefined}
              onChange={e => targets.forEach(d => controls.kelvin(d, Number(e.target.value)))} />
          </label>
          <p className="note">Color and white replace the current whole-fixture output, a Nanoleaf design or scene included. Hardware limits still apply.</p>
          {active.length !== 1 && targets.some(isShapesWall) && <p className="note">Select one Nanoleaf wall on its own to paint its panels.</p>}
          {active.length === 1 && <details><summary>Fixture details</summary>
            <ul className="inspector-list"><LightCard device={devices.find(d => d.id === active[0])!} controls={controls} compact showFavorite={supportsSavedLighting} /></ul>
          </details>}
          {supportsSavedLighting && <details className="scene-capture"><summary>Save current lighting</summary>
            <SceneCapture devices={devices} scopeName={scopeName} onSave={onSaveScene} showHeading={false} />
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

function EmptyLights({ scanning, onScan, onSetupRoom }: {
  scanning: boolean; onScan: () => void; onSetupRoom?: () => void
}) {
  return (
    <div className="panel">
      <h2>No lights found yet</h2>
      <p>
        The bridge is running but has not heard from any lights. LIFX bulbs answer automatically;
        Govee devices must have <strong>LAN Control</strong> enabled in the Govee Home app. Nanoleaf
        Shapes and Aurora walls are paired once from <strong>Devices</strong>.
      </p>
      <button className="primary" onClick={onScan} disabled={scanning}>
        {scanning ? 'Scanning…' : 'Scan for lights'}
      </button>
      {onSetupRoom && <button onClick={onSetupRoom}>Set up a room</button>}
    </div>
  )
}

// MARK: Library (scenes)

export function LibraryView({
  scenes,
  devices,
  allDevices,
  rooms,
  scopeName,
  onSave,
  onApply,
  onDelete,
}: {
  scenes: Scene[]
  devices: Device[]
  allDevices: Device[]
  rooms: Room[]
  scopeName: string
  onSave: (name: string) => Promise<boolean>
  onApply: (scene: Scene) => void
  onDelete: (scene: Scene) => void
}) {
  return (
    <section>
      <div className="panel">
        <SceneCapture devices={devices} scopeName={scopeName} onSave={onSave} />
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
              <SceneScope scene={scene} devices={allDevices} rooms={rooms}
                currentDevices={devices} scopeName={scopeName} />
              <div className="whites">
                <button className="primary" onClick={() => onApply(scene)} disabled={!Object.keys(scene.snapshots ?? {}).length}>
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

function SceneScope({ scene, devices, rooms, currentDevices, scopeName }: {
  scene: Scene; devices: Device[]; rooms: Room[]; currentDevices: Device[]; scopeName: string
}) {
  const currentIDs = new Set(currentDevices.map(device => device.id))
  const saved = Object.keys(scene.snapshots ?? {}).map(id => {
    const device = devices.find(candidate => candidate.id === id)
    const room = device && rooms.find(candidate => candidate.lightIDs.includes(id))
    return {
      id,
      name: device?.name ?? `Unavailable fixture (${id})`,
      room: room?.name ?? (device ? 'No room' : 'Unknown room'),
      lighting: describeSavedLighting(scene.snapshots[id], device?.brand),
      missing: !device,
      unavailable: !device || !device.reachable || Boolean(device.needsPairing),
      outside: Boolean(device) && !currentIDs.has(id),
    }
  })
  const unavailable = saved.filter(fixture => fixture.unavailable).length
  const outside = saved.filter(fixture => fixture.outside).length
  const missing = saved.some(fixture => fixture.missing)
  const roomCounts = new Map<string, number>()
  saved.forEach(fixture => roomCounts.set(fixture.room, (roomCounts.get(fixture.room) ?? 0) + 1))

  return <div className="scene-scope">
    <p className="note">Saved fixtures: {saved.length
      ? saved.slice(0, 3).map(fixture => fixture.name).join(', ') + (saved.length > 3 ? ` and ${saved.length - 3} more` : '')
      : 'None'}.</p>
    {saved.length > 0 && <>
      <p className="note">Current rooms: {Array.from(roomCounts, ([room, count]) => `${room} (${count})`).join(', ')}.</p>
      <p className={outside || unavailable ? 'note warn' : 'note'}>
        {outside ? `${outside} saved fixture${outside === 1 ? '' : 's'} outside ${scopeName} will also be recalled. `
          : missing ? 'Recall uses the saved fixtures shown below. ' : `All saved fixtures are in ${scopeName}. `}
        {unavailable ? `${unavailable} unavailable fixture${unavailable === 1 ? '' : 's'} may be skipped.` : 'All are available.'}
      </p>
      <details><summary>View all {saved.length} saved fixture{saved.length === 1 ? '' : 's'}</summary>
        <ul className="scene-fixture-list">{saved.map(fixture => <li key={fixture.id}>
          <strong>{fixture.name}</strong> · {fixture.room} · {fixture.lighting}
          {fixture.outside && <span> · Outside {scopeName}</span>}
          {fixture.unavailable && <span className="warn"> · Unavailable</span>}
        </li>)}</ul>
      </details>
    </>}
  </div>
}

type SavedLighting = {
  isOn?: boolean; power?: boolean; brightness?: number; color?: RGB | null; kelvin?: number | null
  hsbk?: { saturation?: number; kelvin?: number } | null
  design?: Record<string, unknown> | null; effect?: string | null
}

function colorName(rgb: RGB): string {
  const { h, s, v } = toTone(rgb)
  if (v < .08) return 'black'
  if (s < .12) return v < .35 ? 'dark gray' : v < .75 ? 'gray' : 'white'
  if (h < 15 || h >= 335) return 'red'
  if (h < 45) return 'orange'
  if (h < 70) return 'yellow'
  if (h < 160) return 'green'
  if (h < 200) return 'cyan'
  if (h < 255) return 'blue'
  if (h < 290) return 'purple'
  return 'pink'
}

function describeSavedLighting(value: unknown, brand?: Device['brand']): string {
  if (!value || typeof value !== 'object') return 'Saved output unavailable'
  const saved = value as SavedLighting
  const power = saved.isOn ?? saved.power
  const parts = [power == null ? 'Power unknown' : power ? 'On' : 'Off']
  if (typeof saved.brightness === 'number') parts.push(`${saved.brightness}% brightness`)
  const kelvin = saved.hsbk?.kelvin ?? saved.kelvin
  const hasKelvin = typeof kelvin === 'number' && kelvin > 0
  if (saved.effect) parts.push(`controller scene “${saved.effect}”`)
  else if (saved.design) parts.push(`panel design for ${Object.keys(saved.design).length} panels`)
  else if (hasKelvin && (saved.hsbk?.saturation === 0 || (brand !== 'lifx' && brand != null) || !saved.color)) {
    parts.push(`${kelvin} K white`)
  } else {
    if (saved.color) parts.push(`${colorName(saved.color)} ${rgbToHex(saved.color).toUpperCase()}`)
    if (hasKelvin) parts.push(`saved temperature ${kelvin} K`)
  }
  return parts.join(' · ')
}

function SceneScore({ scene }: { scene: Scene }) {
  return <div className="scene-score" role="img"
    aria-label={`${scene.name}: saved colors and levels for ${Object.keys(scene.snapshots ?? {}).length} fixtures. Expand the saved fixture list for each value.`}>
    {Object.keys(scene.snapshots ?? {}).sort().map(id => {
      const s = scene.snapshots[id] as { isOn?: boolean; power?: boolean; brightness?: number; color?: {r:number;g:number;b:number} }
      const isOn = s.isOn ?? s.power
      return <span key={id} style={{
        background: s.color ? rgbToHex(s.color) : 'var(--secondary)',
        height: isOn === false ? 3 : 8 + Math.max(0, Math.min(100, s.brightness ?? 50)) * 0.3,
        opacity: isOn === false ? 0.25 : 1,
      }} />
    })}
  </div>
}

// MARK: Devices

function ShapesPairing({ onPair }: { onPair: (host: string, port: number) => Promise<void> }) {
  const [host, setHost] = useState('')
  const [port, setPort] = useState('16021')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  return (
    <div className="panel">
      <h2>Pair a Nanoleaf Shapes or Aurora wall</h2>
      <ol className="steps">
        <li>Find the controller’s IP address in your router’s list of connected devices and enter it below.</li>
        <li>Hold the controller’s power button for 5–7 seconds, until its LED flashes.</li>
        <li>Within 30 seconds, choose Pair.</li>
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
  onAddRoom: (name: string) => Promise<boolean>
  onDeleteRoom: (room: Room) => void
  onPairShapes: (host: string, port: number) => Promise<void>
  onForgetShapes: (d: Device) => void
  onScan: () => void
  scanning: boolean
}) {
  const [roomName, setRoomName] = useState('')
  const [addingRoom, setAddingRoom] = useState(false)

  return (
    <section>
      <div className="panel">
        <h2>Rooms</h2>
        <p>Group lights so scenes and schedules can act on them together.</p>
        <form
          className="inline-form"
          onSubmit={async e => {
            e.preventDefault()
            if (addingRoom || !roomName.trim()) return
            setAddingRoom(true)
            try {
              if (await onAddRoom(roomName.trim())) setRoomName('')
            } finally {
              setAddingRoom(false)
            }
          }}
        >
          <input
            type="text"
            aria-label="Room name"
            placeholder="Room name, e.g. Studio"
            value={roomName}
            onChange={e => setRoomName(e.target.value)}
            maxLength={60}
            disabled={addingRoom}
          />
          <button className="primary" type="submit" disabled={addingRoom || !roomName.trim()}>
            {addingRoom ? 'Adding…' : 'Add room'}
          </button>
        </form>
        {rooms.length > 0 && (
          <ul className="pills">
            {rooms.map(r => (
              <li key={r.id} className="pill">
                {r.name} <span className="count">{r.lightIDs.length}</span>
                <button className="pill-x" onClick={() => {
                  const lights = r.lightIDs.length ? ` ${r.lightIDs.length} light${r.lightIDs.length === 1 ? '' : 's'} will be moved to No room.` : ''
                  const schedules = r.schedules.length ? ` ${r.schedules.length} schedule${r.schedules.length === 1 ? '' : 's'} will be deleted.` : ''
                  if (window.confirm(`Delete “${r.name}”?${lights}${schedules} This cannot be undone in the browser.`)) onDeleteRoom(r)
                }} aria-label={`Delete ${r.name}`}>
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
                <DeviceName device={d} onRename={controls.rename} />
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
  connected,
  onPortChange,
  onScan,
  scanning,
}: {
  port: number
  servedByBridge: boolean
  deviceCount: number
  connected: boolean
  onPortChange: (port: number) => void
  onScan: () => void
  scanning: boolean
}) {
  const [portText, setPortText] = useState(String(port))
  useEffect(() => setPortText(String(port)), [port])
  const nextPort = Number(portText)
  const validPort = Number.isInteger(nextPort) && nextPort >= 1 && nextPort <= 65535
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
        {!servedByBridge && <form className="inline-form" onSubmit={event => {
          event.preventDefault()
          if (validPort && nextPort !== port) onPortChange(nextPort)
        }}>
          <label className="port">Bridge port
            <input type="number" min={1} max={65535} required value={portText}
              onChange={event => setPortText(event.target.value)} />
          </label>
          <button type="submit" disabled={!validPort || nextPort === port}>Connect to port</button>
        </form>}
        <button className="ghost" onClick={onScan} disabled={!connected || scanning}>
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
          Nanoleaf music are native-app features. In the browser, Music Mode drives every fixture,
          Nanoleaf walls included, as one colour.
        </p>
      </div>
    </section>
  )
}
