import { useState } from 'react'

type Route = 'home' | 'library' | 'automation' | 'devices' | 'settings' | 'room' | 'light' | 'segment'
type Connectivity = 'online' | 'offline' | 'stale'
type CommandPhase = 'confirmed' | 'sending' | 'applied' | 'failed'
type Vendor = 'LIFX' | 'Govee'
type LibraryTab = 'scenes' | 'themes' | 'effects'

type Segment = { color: string; brightness: number }
type Device = {
  id: string
  name: string
  model: string
  vendor: Vendor
  roomId: string
  on: boolean
  brightness: number
  color: string
  kelvin: number
  connectivity: Connectivity
  favorite?: boolean
  segmentCapable?: boolean
  segments?: Segment[]
}

type Room = { id: string; name: string; favorite?: boolean; automationPaused?: boolean }
type Scene = { id: string; name: string; colors: string[]; favorite: boolean; detail: string }

const initialRooms: Room[] = [
  { id: 'living', name: 'Living Room', favorite: true },
  { id: 'office', name: 'Studio Office' },
  { id: 'bedroom', name: 'Bedroom', automationPaused: true },
]

const segmentColors = ['#FF5470', '#FF8B4A', '#FFD45C', '#C8FF5B', '#39E6C9', '#62C8FF', '#8B7BFF', '#F06BFF', '#FF5470', '#FFD45C', '#39E6C9', '#8B7BFF']

const initialDevices: Device[] = [
  { id: 'arc', name: 'Window Arc', model: 'LIFX Beam', vendor: 'LIFX', roomId: 'living', on: true, brightness: 72, color: '#9A6BFF', kelvin: 3500, connectivity: 'online', favorite: true },
  { id: 'cove', name: 'Media Cove', model: 'Govee H619C', vendor: 'Govee', roomId: 'living', on: true, brightness: 64, color: '#2ED6C4', kelvin: 4000, connectivity: 'online', segmentCapable: true, segments: segmentColors.map((color) => ({ color, brightness: 78 })) },
  { id: 'lamp', name: 'Reading Lamp', model: 'LIFX Color A19', vendor: 'LIFX', roomId: 'living', on: false, brightness: 48, color: '#FFD39C', kelvin: 3000, connectivity: 'stale' },
  { id: 'desk', name: 'Desk Wash', model: 'LIFX Lightstrip', vendor: 'LIFX', roomId: 'office', on: true, brightness: 82, color: '#66D8FF', kelvin: 5000, connectivity: 'online', favorite: true },
  { id: 'rope', name: 'Shelf Rope', model: 'Govee H61D3', vendor: 'Govee', roomId: 'office', on: true, brightness: 58, color: '#FF6DCB', kelvin: 4000, connectivity: 'online', segmentCapable: true, segments: segmentColors.slice().reverse().map((color) => ({ color, brightness: 62 })) },
  { id: 'key', name: 'Key Light', model: 'LIFX BR30', vendor: 'LIFX', roomId: 'office', on: false, brightness: 42, color: '#FFF0D6', kelvin: 4400, connectivity: 'online' },
  { id: 'bed', name: 'Bedside Glow', model: 'Govee H6008', vendor: 'Govee', roomId: 'bedroom', on: true, brightness: 24, color: '#FF8B61', kelvin: 2700, connectivity: 'online' },
  { id: 'ceiling', name: 'Ceiling', model: 'LIFX Mini Color', vendor: 'LIFX', roomId: 'bedroom', on: false, brightness: 55, color: '#FFE9C7', kelvin: 3200, connectivity: 'offline' },
]

const themes = [
  { id: 'aurora', name: 'Aurora Veil', category: 'Nature', detail: 'Cool greens and violet sky color.', colors: ['#42E8C7', '#49B9FF', '#8C72FF', '#E164FF'] },
  { id: 'afterglow', name: 'Afterglow', category: 'Atmosphere', detail: 'Warm horizon color for a calm evening.', colors: ['#FF6B5B', '#FF9F5A', '#FFD06B', '#8E62FF'] },
  { id: 'deepwork', name: 'Deep Work', category: 'Focus', detail: 'Clean whites with a quiet cyan edge.', colors: ['#FFF1D8', '#D8F5FF', '#80DFFF', '#4169E1'] },
  { id: 'moon', name: 'Moon Garden', category: 'Nature', detail: 'Low, cool, and restorative.', colors: ['#263E66', '#496AA1', '#7D76CF', '#A5D8CE'] },
]

const effects = [
  { id: 'flow', name: 'Color Flow', detail: 'A slow spectrum drift across the selected lights.', colors: ['#31E6C3', '#6C86FF', '#E36AFF'] },
  { id: 'ocean', name: 'Ocean Wave', detail: 'Layered blue and cyan movement.', colors: ['#0B5FFF', '#2FD8E8', '#A0FFF0'] },
  { id: 'candle', name: 'Candlelight', detail: 'A low, natural warm flicker.', colors: ['#FF7B31', '#FFC45E', '#FFE2A8'] },
]

const initialScenes: Scene[] = [
  { id: 'evening', name: 'Soft Landing', colors: ['#FF9168', '#B06FFF', '#4D7EFF'], favorite: true, detail: 'Living Room · 3 lights · captured yesterday' },
  { id: 'focus', name: 'Studio Focus', colors: ['#DFF8FF', '#77D8FF', '#6677FF'], favorite: false, detail: 'Studio Office · 3 lights · captured Friday' },
]

const navItems: { id: Route; label: string; icon: string }[] = [
  { id: 'home', label: 'Home', icon: '⌂' },
  { id: 'library', label: 'Library', icon: '✦' },
  { id: 'automation', label: 'Automation', icon: '◷' },
  { id: 'devices', label: 'Devices', icon: '⌁' },
  { id: 'settings', label: 'Settings', icon: '⚙' },
]

function cx(...classes: Array<string | false | undefined>) {
  return classes.filter(Boolean).join(' ')
}

function StatusBadge({ phase, label }: { phase: CommandPhase | Connectivity | 'paused' | 'running' | 'demo'; label?: string }) {
  const labels: Record<string, string> = {
    online: 'Online', offline: 'Offline', stale: 'Stale', confirmed: 'Confirmed by device', sending: 'Sending', applied: 'Applied locally', failed: 'Failed', paused: 'Automation paused', running: 'Effect running', demo: 'Demo — no devices controlled',
  }
  const icons: Record<string, string> = { online: '●', offline: '⊘', stale: '◷', confirmed: '✓', sending: '↥', applied: '✓', failed: '!', paused: 'Ⅱ', running: '≈', demo: '◇' }
  return <span className={cx('status-badge', `is-${phase}`)}><span aria-hidden="true">{icons[phase]}</span>{label ?? labels[phase]}</span>
}

function Toggle({ checked, onChange, label, disabled = false }: { checked: boolean; onChange: (value: boolean) => void; label: string; disabled?: boolean }) {
  return <button className={cx('toggle', checked && 'is-on')} type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} onClick={() => onChange(!checked)}><span /></button>
}

function Modal({ title, children, onClose, wide = false }: { title: string; children: React.ReactNode; onClose: () => void; wide?: boolean }) {
  return <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.currentTarget === event.target) onClose() }}>
    <section className={cx('modal', wide && 'modal-wide')} role="dialog" aria-modal="true" aria-labelledby="modal-title">
      <div className="modal-header"><div><p className="eyebrow">LumenDesk</p><h2 id="modal-title">{title}</h2></div><button className="icon-button" type="button" onClick={onClose} aria-label={`Close ${title}`}>×</button></div>
      {children}
    </section>
  </div>
}

function Onboarding({ onFinish, onDemo }: { onFinish: () => void; onDemo: () => void }) {
  const steps = ['Welcome', 'Privacy', 'Prepare', 'Discover', 'Review', 'Organize', 'Ready']
  const [step, setStep] = useState(0)
  const [scanState, setScanState] = useState<'idle' | 'scanning' | 'found' | 'empty' | 'denied'>('idle')
  const [roomName, setRoomName] = useState('Living Room')
  const next = () => setStep((value) => Math.min(steps.length - 1, value + 1))
  const runScan = (outcome: 'found' | 'empty' | 'denied' = 'found') => {
    setScanState('scanning')
    window.setTimeout(() => setScanState(outcome), 1100)
  }

  return <main className="onboarding-shell">
    <aside className="setup-progress" aria-label="Setup progress">
      <div className="brand-lockup"><span className="brand-mark">◒</span><span>LumenDesk</span></div>
      <ol>{steps.map((item, index) => <li key={item} className={cx(index === step && 'current', index < step && 'done')}><span>{index < step ? '✓' : index + 1}</span>{item}</li>)}</ol>
      <p className="privacy-note">Local control only<br />No account · No cloud</p>
    </aside>
    <section className="setup-content">
      <div className="setup-card">
        {step === 0 && <>
          <span className="hero-orb" aria-hidden="true">◒</span><p className="eyebrow">A private lighting instrument</p><h1>Your lights. Your network.<br /><span className="gradient-text">Your atmosphere.</span></h1>
          <p className="lede">Control supported LIFX and Govee lights directly over your local network—fast, private, and without an account or bridge.</p>
          <div className="value-grid"><article><b>Fast control</b><span>Power, brightness, and color without a cloud round trip.</span></article><article><b>Creative depth</b><span>Scenes, effects, schedules, and RGBIC segment painting.</span></article><article><b>Honest status</b><span>See when a command is sent, applied, confirmed, or needs help.</span></article></div>
        </>}
        {step === 1 && <>
          <p className="eyebrow">Before the system prompt</p><h1>Allow Local Network access</h1><p className="lede">LumenDesk uses this permission only to find and control lights on the Wi-Fi network you are using. It does not send your lighting data to a server.</p>
          <div className="permission-preview"><span>⌁</span><div><b>Why it is needed</b><p>Discovery and lighting commands travel directly between this device and your lights.</p></div></div>
          <p className="caption">The next step may trigger Apple’s real system permission dialog. This is a preparation screen, not a copy of that dialog.</p>
        </>}
        {step === 2 && <>
          <p className="eyebrow">Prepare your lights</p><h1>Two quick checks</h1><div className="checklist"><label><input type="checkbox" defaultChecked /><span><b>LIFX lights are powered on</b><small>Keep this device and the lights on the same Wi-Fi or local network.</small></span></label><label><input type="checkbox" /><span><b>Govee LAN Control is enabled</b><small>In the Govee Home app, open each supported device and enable LAN Control.</small></span></label></div>
          <details><summary>Where is Govee LAN Control?</summary><p>Open the Govee device, choose Settings, then enable LAN Control. Some models do not expose this option and cannot be controlled locally.</p></details>
        </>}
        {step === 3 && <>
          <p className="eyebrow">Local discovery</p><h1>{scanState === 'scanning' ? 'Looking for lights…' : scanState === 'found' ? '8 lights found' : scanState === 'empty' ? 'No lights responded' : scanState === 'denied' ? 'Local Network is off' : 'Find your lights'}</h1>
          <div className={cx('scan-visual', scanState === 'scanning' && 'is-scanning')}><span>⌁</span><i /><i /><i /></div>
          {scanState === 'idle' && <p className="lede">Discovery searches only this local network. No vendor login is required.</p>}
          {scanState === 'scanning' && <p className="lede" role="status">Scanning LIFX broadcast and Govee LAN devices…</p>}
          {scanState === 'found' && <div className="success-panel"><StatusBadge phase="confirmed" label="6 online · 1 stale · 1 offline" /><p>Mixed connectivity is normal during setup; you can continue and retry missing lights later.</p></div>}
          {scanState === 'empty' && <div className="recovery-panel"><b>No devices found</b><p>Check that lights are powered, avoid guest Wi-Fi, and confirm Govee LAN Control. Then scan again.</p><button className="button secondary" onClick={() => runScan()}>Scan again</button></div>}
          {scanState === 'denied' && <div className="recovery-panel"><b>Permission denied</b><p>Enable Local Network for LumenDesk in Settings, then return and scan again.</p><button className="button secondary">Open Settings</button></div>}
          {scanState === 'idle' && <div className="button-row"><button className="button primary" onClick={() => runScan()}>Start discovery</button><button className="button ghost" onClick={() => runScan('empty')}>Show no-results state</button><button className="button ghost" onClick={() => runScan('denied')}>Show denied state</button></div>}
        </>}
        {step === 4 && <>
          <p className="eyebrow">Review discovery</p><h1>Name what you found</h1><p className="lede">Clear names make room control, schedules, and the menu bar faster.</p>
          <div className="discovery-list">{initialDevices.slice(0, 5).map((device) => <div className="discovery-row" key={device.id}><span className="device-dot" style={{ '--light-color': device.color } as React.CSSProperties} /><input aria-label={`Name ${device.model}`} defaultValue={device.name} /><span>{device.vendor}</span><StatusBadge phase={device.connectivity} /></div>)}</div>
        </>}
        {step === 5 && <>
          <p className="eyebrow">Organize</p><h1>Create a room</h1><p className="lede">Rooms can mix LIFX and Govee devices. Drag or check devices to assign them.</p>
          <label className="field"><span>Room name</span><input value={roomName} onChange={(event) => setRoomName(event.target.value)} /></label>
          <div className="assignment-grid"><article><b>Available lights</b>{initialDevices.slice(0, 4).map((device, index) => <label key={device.id}><input type="checkbox" defaultChecked={index < 3} />{device.name}<small>{device.vendor}</small></label>)}</article><article className="room-drop"><span>▣</span><b>{roomName || 'New Room'}</b><p>3 lights assigned</p></article></div>
        </>}
        {step === 6 && <>
          <span className="hero-orb success" aria-hidden="true">✓</span><p className="eyebrow">Setup complete</p><h1>Your workspace is ready</h1><p className="lede">Eight lights across three rooms are ready for local control. You can rename, move, or troubleshoot devices any time.</p>
          <div className="setup-summary"><div><b>8</b><span>lights found</span></div><div><b>3</b><span>rooms</span></div><div><b>Local</b><span>control path</span></div></div>
        </>}
        <footer className="setup-footer"><button className="button ghost" onClick={step === 0 ? onDemo : () => setStep((value) => Math.max(0, value - 1))}>{step === 0 ? 'Explore Demo Mode' : 'Back'}</button><span>Step {step + 1} of {steps.length}</span>{step === 6 ? <button className="button primary" onClick={onFinish}>Enter Home</button> : <button className="button primary" onClick={next} disabled={step === 3 && scanState !== 'found'}>Continue</button>}</footer>
      </div>
    </section>
  </main>
}

function RoomCard({ room, devices, onOpen, onPower }: { room: Room; devices: Device[]; onOpen: () => void; onPower: (value: boolean) => void }) {
  const online = devices.filter((device) => device.connectivity === 'online').length
  const onCount = devices.filter((device) => device.on).length
  const avg = onCount ? Math.round(devices.filter((device) => device.on).reduce((sum, device) => sum + device.brightness, 0) / onCount) : 0
  return <article className="room-card interactive-card">
    <button className="card-hit-area" type="button" onClick={onOpen} aria-label={`Open ${room.name}`} />
    <div className="card-heading"><button className="card-title-button" onClick={onOpen}><span className="room-icon">▣</span><span><b>{room.name}</b><small>{online} of {devices.length} online · {onCount} on</small></span></button><Toggle checked={onCount > 0} onChange={onPower} label={`Turn ${room.name} ${onCount ? 'off' : 'on'}`} /></div>
    <div className="room-palette" aria-label={`${room.name} colors`}>{devices.map((device) => <span key={device.id} style={{ background: device.color, opacity: device.on ? 1 : .2 }} />)}</div>
    <div className="room-metrics"><span><b>{avg}%</b> brightness</span>{devices.some((device) => device.connectivity !== 'online') ? <StatusBadge phase="offline" label={`${devices.filter((device) => device.connectivity !== 'online').length} needs attention`} /> : <StatusBadge phase="online" />}</div>
    {room.automationPaused ? <StatusBadge phase="paused" /> : <span className="quiet-meta">Next: Wind down · 10:30 PM</span>}
  </article>
}

function LightCard({ device, command, compact, selected, selectionMode, onSelect, onPower, onOpen, onRetry }: { device: Device; command: CommandPhase; compact: boolean; selected: boolean; selectionMode: boolean; onSelect: () => void; onPower: (value: boolean) => void; onOpen: () => void; onRetry: () => void }) {
  const status = command !== 'confirmed' ? command : device.connectivity
  return <article className={cx('light-card', compact && 'compact', selected && 'is-selected', device.connectivity !== 'online' && 'is-disconnected')}>
    <button className="card-hit-area" type="button" onClick={selectionMode ? onSelect : onOpen} aria-label={selectionMode ? `${selected ? 'Deselect' : 'Select'} ${device.name}` : `Open ${device.name}`} />
    <div className="light-card-top"><button className="light-identity" onClick={selectionMode ? onSelect : onOpen} aria-pressed={selectionMode ? selected : undefined}><span className="light-orb" style={{ '--light-color': device.color } as React.CSSProperties}>{selected ? '✓' : '●'}</span><span><b>{device.name}</b><small>{device.vendor} · {device.model}</small></span></button>{selectionMode ? <button className="select-check" onClick={onSelect} aria-label={`${selected ? 'Deselect' : 'Select'} ${device.name}`}>{selected ? '✓' : ''}</button> : <Toggle checked={device.on} onChange={onPower} label={`Turn ${device.name} ${device.on ? 'off' : 'on'}`} disabled={device.connectivity === 'offline'} />}</div>
    {!compact && <div className="slider-row"><span aria-hidden="true">☼</span><input type="range" min="1" max="100" value={device.brightness} aria-label={`${device.name} brightness`} disabled={!device.on || device.connectivity === 'offline'} readOnly /><output>{device.brightness}%</output></div>}
    <div className="light-footer"><StatusBadge phase={status} />{command === 'failed' ? <button className="text-button danger" onClick={onRetry}>Retry</button> : <button className="text-button" onClick={onOpen}>{device.segmentCapable ? 'Open · Segment Studio' : 'Open controls'}</button>}</div>
  </article>
}

function HomeView({ rooms, devices, commands, scenes, activeEffect, demoMode, onOpenRoom, onOpenLight, onNavigate, runCommand, retryCommand, setDevices }: {
  rooms: Room[]; devices: Device[]; commands: Record<string, CommandPhase>; scenes: Scene[]; activeEffect: string | null; demoMode: boolean; onOpenRoom: (id: string) => void; onOpenLight: (id: string) => void; onNavigate: (route: Route) => void; runCommand: (id: string, patch: Partial<Device>) => void; retryCommand: (id: string) => void; setDevices: React.Dispatch<React.SetStateAction<Device[]>>
}) {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<'all' | 'on' | 'offline'>('all')
  const [density, setDensity] = useState<'comfortable' | 'compact'>('comfortable')
  const [selecting, setSelecting] = useState(false)
  const [selected, setSelected] = useState<string[]>([])
  const shown = devices.filter((device) => device.name.toLowerCase().includes(query.toLowerCase()) && (filter === 'all' || (filter === 'on' ? device.on : device.connectivity !== 'online')))
  const onCount = devices.filter((device) => device.on).length
  const onlineCount = devices.filter((device) => device.connectivity === 'online').length
  const globalPower = (value: boolean) => devices.filter((device) => device.connectivity !== 'offline').forEach((device) => runCommand(device.id, { on: value }))
  const bulkPower = (value: boolean) => selected.forEach((id) => runCommand(id, { on: value }))

  return <>
    {demoMode && <div className="demo-banner"><StatusBadge phase="demo" /><span>Controls stay interactive for exploration.</span><button className="text-button">Return to Live in Settings</button></div>}
    <section className="hero-status">
      <div><p className="eyebrow">Current lighting</p><h1>{onCount ? `${onCount} lights are shaping the space` : 'The space is quiet'}</h1><p>{onlineCount} of {devices.length} devices online · Commands stay on this network</p></div>
      <div className="global-control"><div><span className="mood-orb" /><span><b>All lights</b><small>{onCount} on · {Math.round(devices.filter((d) => d.on).reduce((s, d) => s + d.brightness, 0) / Math.max(1, onCount))}% average</small></span></div><Toggle checked={onCount > 0} onChange={globalPower} label="Toggle all lights" /></div>
    </section>
    <section className="section-block">
      <div className="section-heading"><div><p className="eyebrow">One tap away</p><h2>Favorites</h2></div><button className="text-button" onClick={() => onNavigate('library')}>Manage</button></div>
      <div className="favorites-row">{scenes.filter((scene) => scene.favorite).map((scene) => <button className="favorite-tile" key={scene.id} onClick={() => onNavigate('library')}><span className="mini-palette">{scene.colors.map((color) => <i key={color} style={{ background: color }} />)}</span><span><b>{scene.name}</b><small>Scene · Restore</small></span></button>)}{devices.filter((device) => device.favorite).map((device) => <button className="favorite-tile" key={device.id} onClick={() => onOpenLight(device.id)}><span className="favorite-orb" style={{ background: device.color }} /><span><b>{device.name}</b><small>Light · {device.on ? `${device.brightness}%` : 'Off'}</small></span></button>)}</div>
    </section>
    <div className="home-split">
      <section className="section-block"><div className="section-heading"><div><p className="eyebrow">Spaces</p><h2>Rooms</h2></div><button className="text-button" onClick={() => onNavigate('devices')}>Organize</button></div><div className="room-grid">{rooms.map((room) => <RoomCard key={room.id} room={room} devices={devices.filter((device) => device.roomId === room.id)} onOpen={() => onOpenRoom(room.id)} onPower={(value) => devices.filter((device) => device.roomId === room.id && device.connectivity !== 'offline').forEach((device) => runCommand(device.id, { on: value }))} />)}</div></section>
      <aside className="now-panel"><p className="eyebrow">Now & next</p>{activeEffect ? <div className="now-item active"><span className="now-icon">≈</span><div><b>{effects.find((effect) => effect.id === activeEffect)?.name}</b><small>Running · All lights</small></div><button className="text-button" onClick={() => onNavigate('library')}>Manage</button></div> : <div className="now-item"><span className="now-icon">✦</span><div><b>No active effects</b><small>Choose motion in Library</small></div></div>}<div className="now-item"><span className="now-icon">◷</span><div><b>Wind down</b><small>10:30 PM · Bedroom</small></div><button className="text-button" onClick={() => onNavigate('automation')}>View</button></div><div className="now-item warning"><span className="now-icon">!</span><div><b>1 missed action</b><small>Ceiling was offline</small></div><button className="text-button" onClick={() => onNavigate('automation')}>Review</button></div></aside>
    </div>
    <section className="section-block lights-section">
      <div className="section-heading responsive"><div><p className="eyebrow">Direct control</p><h2>Individual lights</h2></div><div className="toolbar-actions"><button className={cx('button small', selecting ? 'primary' : 'secondary')} onClick={() => { setSelecting(!selecting); if (selecting) setSelected([]) }}>{selecting ? 'Done' : 'Select'}</button><div className="segmented-button" role="group" aria-label="Interface density"><button className={density === 'comfortable' ? 'active' : ''} type="button" aria-label="Comfortable density" aria-pressed={density === 'comfortable'} onClick={() => setDensity('comfortable')}>▦</button><button className={density === 'compact' ? 'active' : ''} type="button" aria-label="Compact density" aria-pressed={density === 'compact'} onClick={() => setDensity('compact')}>☷</button></div></div></div>
      <div className="filter-bar"><label className="search-field"><span aria-hidden="true">⌕</span><input placeholder="Search lights" value={query} onChange={(event) => setQuery(event.target.value)} /></label><div className="filter-pills">{(['all', 'on', 'offline'] as const).map((item) => <button key={item} className={filter === item ? 'active' : ''} onClick={() => setFilter(item)}>{item === 'all' ? 'All' : item === 'on' ? 'On now' : 'Needs attention'}</button>)}</div></div>
      <div className={cx('light-grid', density === 'compact' && 'compact-grid')}>{shown.map((device) => <LightCard key={device.id} device={device} command={commands[device.id] ?? 'confirmed'} compact={density === 'compact'} selected={selected.includes(device.id)} selectionMode={selecting} onSelect={() => setSelected((items) => items.includes(device.id) ? items.filter((id) => id !== device.id) : [...items, device.id])} onPower={(on) => runCommand(device.id, { on })} onOpen={() => onOpenLight(device.id)} onRetry={() => retryCommand(device.id)} />)}</div>
      {!shown.length && <div className="empty-state"><span>⌕</span><b>No lights match this view</b><p>Clear search or change the active filter.</p><button className="button secondary" onClick={() => { setQuery(''); setFilter('all') }}>Clear filters</button></div>}
    </section>
    {selecting && <div className="bulk-bar"><b>{selected.length} selected</b><span>{selected.filter((id) => !shown.some((device) => device.id === id)).length ? 'Some selected lights are hidden by filters' : 'Visible selection'}</span><button className="button secondary small" disabled={!selected.length} onClick={() => bulkPower(true)}>Turn on</button><button className="button secondary small" disabled={!selected.length} onClick={() => bulkPower(false)}>Turn off</button><label>Brightness <input type="range" min="1" max="100" disabled={!selected.length} onChange={(event) => selected.forEach((id) => runCommand(id, { brightness: Number(event.target.value) }))} /></label><button className="icon-button" onClick={() => { setSelected([]); setSelecting(false) }} aria-label="Exit bulk selection">×</button></div>}
  </>
}

function RoomView({ room, devices, commands, runCommand, onOpenLight, onBack, onPause }: { room: Room; devices: Device[]; commands: Record<string, CommandPhase>; runCommand: (id: string, patch: Partial<Device>) => void; onOpenLight: (id: string) => void; onBack: () => void; onPause: () => void }) {
  const onCount = devices.filter((device) => device.on).length
  const online = devices.filter((device) => device.connectivity === 'online').length
  const [brightness, setBrightness] = useState(Math.round(devices.filter((device) => device.on).reduce((sum, device) => sum + device.brightness, 0) / Math.max(onCount, 1)))
  const swatches = ['#FF8B61', '#FFD45C', '#39E6C9', '#62C8FF', '#8B7BFF', '#F06BFF']
  return <>
    <button className="back-button" onClick={onBack}>‹ Home</button>
    <section className="detail-hero"><div><p className="eyebrow">Room</p><h1>{room.name}</h1><p>{onCount} of {devices.length} on · {online} online</p></div><div className="hero-actions"><button className="button secondary">☆ Favorite</button><Toggle checked={onCount > 0} onChange={(value) => devices.filter((device) => device.connectivity !== 'offline').forEach((device) => runCommand(device.id, { on: value }))} label={`Toggle ${room.name}`} /></div></section>
    <div className="control-layout"><section className="control-card emphasis"><div className="card-heading"><div><p className="eyebrow">Room control</p><h2>{onCount === devices.length ? 'All on' : onCount ? `${onCount} of ${devices.length} on` : 'All off'}</h2></div><StatusBadge phase={online === devices.length ? 'online' : 'offline'} label={online === devices.length ? 'All reachable' : `${devices.length - online} needs attention`} /></div><label className="large-slider"><span>Brightness</span><output>{brightness}%</output><input type="range" min="1" max="100" value={brightness} onChange={(event) => { const value = Number(event.target.value); setBrightness(value); devices.filter((device) => device.on).forEach((device) => runCommand(device.id, { brightness: value })) }} /></label><div className="mode-tabs"><button className="active">Color</button><button>White temperature</button></div><div className="swatch-row">{swatches.map((color) => <button key={color} aria-label={`Set room color ${color}`} style={{ background: color }} onClick={() => devices.filter((device) => device.on).forEach((device) => runCommand(device.id, { color }))} />)}<label className="custom-color">＋<input type="color" aria-label="Custom room color" onChange={(event) => devices.filter((device) => device.on).forEach((device) => runCommand(device.id, { color: event.target.value }))} /></label></div></section>
      <aside className="control-card"><p className="eyebrow">Automation</p><h3>Wind down</h3><p className="secondary-copy">Weekdays · 10:30 PM · Dim to 20%</p>{room.automationPaused ? <div className="paused-panel"><StatusBadge phase="paused" /><p>Schedules remain enabled but will not run until resumed.</p><button className="button primary small" onClick={onPause}>Resume automation</button></div> : <><StatusBadge phase="confirmed" label="Next action tonight" /><button className="button secondary small" onClick={onPause}>Pause automation</button></>}<hr /><p className="eyebrow">Active effect</p><div className="inline-empty">No effect in this room</div></aside>
    </div>
    <section className="section-block"><div className="section-heading"><div><p className="eyebrow">In this room</p><h2>Devices</h2></div><button className="button secondary small">Room menu ···</button></div><div className="light-grid">{devices.map((device) => <LightCard key={device.id} device={device} command={commands[device.id] ?? 'confirmed'} compact={false} selected={false} selectionMode={false} onSelect={() => {}} onPower={(value) => runCommand(device.id, { on: value })} onOpen={() => onOpenLight(device.id)} onRetry={() => runCommand(device.id, {})} />)}</div></section>
  </>
}

function LightView({ device, command, runCommand, retryCommand, onBack, onSegment }: { device: Device; command: CommandPhase; runCommand: (id: string, patch: Partial<Device>) => void; retryCommand: (id: string) => void; onBack: () => void; onSegment: () => void }) {
  const [mode, setMode] = useState<'color' | 'white'>('color')
  const status = command !== 'confirmed' ? command : device.connectivity
  return <>
    <button className="back-button" onClick={onBack}>‹ Back</button>
    <section className="device-detail-grid"><div className="device-preview" style={{ '--light-color': device.color } as React.CSSProperties}><div className="preview-bulb">●</div><span>Live light preview</span></div><div className="device-controls"><div className="detail-title"><div><p className="eyebrow">{device.vendor} · {device.model}</p><h1>{device.name}</h1><StatusBadge phase={status} /></div><Toggle checked={device.on} onChange={(on) => runCommand(device.id, { on })} label={`Toggle ${device.name}`} disabled={device.connectivity === 'offline'} /></div>
      {command === 'failed' && <div className="recovery-panel"><b>Command was not confirmed</b><p>The light did not answer in time. Your requested state is preserved and can be retried.</p><button className="button primary small" onClick={() => retryCommand(device.id)}>Retry command</button><button className="button secondary small">Rescan device</button></div>}
      {device.connectivity === 'stale' && command !== 'failed' && <div className="recovery-panel compact"><StatusBadge phase="stale" /><p>Last response was 12 minutes ago. Controls may still work.</p></div>}
      <label className="large-slider"><span>Brightness</span><output>{device.brightness}%</output><input type="range" min="1" max="100" value={device.brightness} disabled={!device.on || device.connectivity === 'offline'} onChange={(event) => runCommand(device.id, { brightness: Number(event.target.value) })} /></label>
      <div className="mode-tabs"><button className={mode === 'color' ? 'active' : ''} onClick={() => setMode('color')}>Color</button><button className={mode === 'white' ? 'active' : ''} onClick={() => setMode('white')}>White</button></div>
      {mode === 'color' ? <div className="color-editor"><input type="color" value={device.color} aria-label={`${device.name} color`} onChange={(event) => runCommand(device.id, { color: event.target.value })} /><div><b>Current color</b><span>{device.color.toUpperCase()}</span></div><div className="swatch-row">{['#FF6B5B', '#FFB84D', '#3BE1BC', '#58C7FF', '#8B75FF', '#F06BFF'].map((color) => <button key={color} style={{ background: color }} aria-label={`Set color ${color}`} onClick={() => runCommand(device.id, { color })} />)}</div></div> : <label className="temperature-control"><span><b>White temperature</b><output>{device.kelvin} K</output></span><input type="range" min="2500" max="6500" step="100" value={device.kelvin} onChange={(event) => runCommand(device.id, { kelvin: Number(event.target.value) })} /><span className="temperature-scale"><i>Warm</i><i>Neutral</i><i>Cool</i></span></label>}
      {device.segmentCapable && <button className="segment-entry" onClick={onSegment}><span className="mini-segments">{device.segments?.slice(0, 8).map((segment, index) => <i key={index} style={{ background: segment.color }} />)}</span><span><b>Segment Studio</b><small>Paint {device.segments?.length} RGBIC zones</small></span><span>›</span></button>}
      <details className="device-disclosure"><summary>Device details and command truth</summary><dl><div><dt>Desired</dt><dd>{device.on ? `On · ${device.brightness}% · ${device.color}` : 'Off'}</dd></div><div><dt>Confirmed</dt><dd>{command === 'confirmed' ? 'Matches desired state' : 'Previous device state retained'}</dd></div><div><dt>Connection</dt><dd>{device.connectivity} · local network</dd></div><div><dt>Vendor</dt><dd>{device.vendor} LAN</dd></div></dl></details>
    </div></section>
  </>
}

function LibraryView({ scenes, setScenes, activeEffect, setActiveEffect }: { scenes: Scene[]; setScenes: React.Dispatch<React.SetStateAction<Scene[]>>; activeEffect: string | null; setActiveEffect: (id: string | null) => void }) {
  const [tab, setTab] = useState<LibraryTab>('scenes')
  const [query, setQuery] = useState('')
  const [saveOpen, setSaveOpen] = useState(false)
  const [sceneName, setSceneName] = useState('')
  const [favorite, setFavorite] = useState(true)
  const [detail, setDetail] = useState<{ type: LibraryTab; id: string } | null>(null)
  const addScene = () => {
    const name = sceneName.trim()
    if (!name) return
    setScenes((items) => [...items, { id: `scene-${Date.now()}`, name, colors: ['#FF8B61', '#8B7BFF', '#39E6C9'], favorite, detail: 'All lights · captured just now' }])
    setSceneName(''); setSaveOpen(false); setTab('scenes')
  }
  const cards = tab === 'scenes' ? scenes : tab === 'themes' ? themes : effects
  const visible = cards.filter((item) => item.name.toLowerCase().includes(query.toLowerCase()))
  return <>
    <section className="page-heading"><div><p className="eyebrow">Lighting Library</p><h1>Looks worth returning to</h1><p>Captured scenes, curated themes, and animated effects—each with a different job.</p></div><button className="button primary" onClick={() => setSaveOpen(true)}>＋ Save current lighting</button></section>
    {activeEffect && <div className="running-banner"><StatusBadge phase="running" /><div><b>{effects.find((effect) => effect.id === activeEffect)?.name}</b><span>All Lights · state before effect is saved</span></div><button className="button secondary small" onClick={() => setActiveEffect(null)}>Stop effect</button><button className="text-button" onClick={() => setActiveEffect(null)}>Stop & restore previous state</button></div>}
    <div className="library-toolbar"><div className="mode-tabs large" role="tablist">{(['scenes', 'themes', 'effects'] as LibraryTab[]).map((item) => <button key={item} className={tab === item ? 'active' : ''} role="tab" aria-selected={tab === item} onClick={() => setTab(item)}>{item === 'scenes' ? 'My Scenes' : item[0].toUpperCase() + item.slice(1)}</button>)}</div><label className="search-field"><span>⌕</span><input placeholder={`Search ${tab}`} value={query} onChange={(event) => setQuery(event.target.value)} /></label><label className="inline-field"><span>Target</span><select><option>All Lights</option><option>Living Room</option><option>Studio Office</option><option>Bedroom</option></select></label></div>
    <div className="type-explainer"><span><b>{tab === 'scenes' ? 'Captured scene' : tab === 'themes' ? 'Curated theme' : 'Animated effect'}</b>{tab === 'scenes' ? 'A snapshot of your actual devices.' : tab === 'themes' ? 'A static palette adapted to the target.' : 'Motion that runs locally until stopped.'}</span><span>Primary action: <b>{tab === 'scenes' ? 'Restore' : tab === 'themes' ? 'Preview & Apply' : 'Start'}</b></span></div>
    <div className="library-grid">{visible.map((item) => <article className="library-card" key={item.id}><div className="artwork" style={{ background: `linear-gradient(135deg, ${item.colors.join(',')})` }}><span className="type-chip">{tab === 'scenes' ? 'SCENE' : tab === 'themes' ? 'THEME' : 'EFFECT'}</span>{tab === 'effects' && <span className="motion-lines">≈ ≈ ≈</span>}</div><div className="library-card-body"><div><h3>{item.name}</h3><p>{'detail' in item ? item.detail : ''}</p></div><div className="card-actions"><button className="text-button" onClick={() => setDetail({ type: tab, id: item.id })}>Details</button><button className="button primary small" onClick={() => tab === 'effects' ? setActiveEffect(item.id) : setDetail({ type: tab, id: item.id })}>{tab === 'scenes' ? 'Restore' : tab === 'themes' ? 'Preview' : activeEffect === item.id ? 'Running' : 'Start'}</button></div></div></article>)}</div>
    {!visible.length && <div className="empty-state"><span>✦</span><b>No {tab} match</b><p>Try a different search term.</p></div>}
    {saveOpen && <Modal title="Save current lighting as a scene" onClose={() => setSaveOpen(false)}><div className="modal-body"><div className="scene-preview"><span className="mini-palette">{['#FF8B61', '#8B7BFF', '#39E6C9', '#62C8FF'].map((color) => <i key={color} style={{ background: color }} />)}</span><div><b>Current lighting</b><small>6 active · 1 offline light will be included with its last confirmed state</small></div></div><label className="field"><span>Scene name</span><input autoFocus value={sceneName} placeholder="e.g. Sunday evening" onChange={(event) => setSceneName(event.target.value)} /></label><label className="checkbox-row"><input type="checkbox" checked={favorite} onChange={(event) => setFavorite(event.target.checked)} /><span><b>Add to Favorites</b><small>Show this scene on Home and in the menu bar.</small></span></label></div><footer className="modal-actions"><button className="button secondary" onClick={() => setSaveOpen(false)}>Cancel</button><button className="button primary" onClick={addScene} disabled={!sceneName.trim()}>Save scene</button></footer></Modal>}
    {detail && <Modal title={detail.type === 'scenes' ? scenes.find((item) => item.id === detail.id)?.name ?? 'Scene' : detail.type === 'themes' ? themes.find((item) => item.id === detail.id)?.name ?? 'Theme' : effects.find((item) => item.id === detail.id)?.name ?? 'Effect'} onClose={() => setDetail(null)}><div className="modal-body"><div className="detail-art" /><p className="lede">Preview this look against the current target before changing physical lights. The previous state is kept for one-step restore.</p><label className="inline-field"><span>Apply to</span><select><option>All Lights</option><option>Living Room</option><option>Studio Office</option></select></label></div><footer className="modal-actions"><button className="button secondary" onClick={() => setDetail(null)}>Cancel</button><button className="button secondary">Preview</button><button className="button primary" onClick={() => setDetail(null)}>Apply</button></footer></Modal>}
  </>
}

function AutomationView({ rooms, setRooms }: { rooms: Room[]; setRooms: React.Dispatch<React.SetStateAction<Room[]>> }) {
  const [editor, setEditor] = useState(false)
  const [mode, setMode] = useState<'fixed' | 'sunrise' | 'sunset'>('fixed')
  const [days, setDays] = useState(['M', 'T', 'W', 'T2', 'F'])
  const schedules = [
    { id: 'morning', room: 'Studio Office', name: 'Workday start', time: '8:15 AM', action: 'Turn on · 72%', enabled: true },
    { id: 'wind', room: 'Bedroom', name: 'Wind down', time: '10:30 PM', action: 'Dim to 20%', enabled: true },
    { id: 'sun', room: 'Living Room', name: 'Golden hour', time: 'Sunset − 20 min', action: 'Apply Afterglow', enabled: false },
  ]
  const pauseRoom = (id: string, paused: boolean) => setRooms((items) => items.map((room) => room.id === id ? { ...room, automationPaused: paused } : room))
  return <>
    <section className="page-heading"><div><p className="eyebrow">Automation</p><h1>Routines, with a clear pause button</h1><p>Schedules can stay enabled while a room is temporarily paused.</p></div><button className="button primary" onClick={() => setEditor(true)}>＋ Add schedule</button></section>
    <div className="missed-banner"><span className="alert-icon">!</span><div><b>1 action was missed</b><span>Bedroom Ceiling was offline at 7:00 AM. No later actions were blocked.</span></div><button className="button secondary small">Review</button><button className="text-button">Dismiss</button></div>
    <section className="section-block"><div className="section-heading"><div><p className="eyebrow">Room-level state</p><h2>Automation status</h2></div></div><div className="automation-room-grid">{rooms.map((room) => <article key={room.id} className={cx('automation-room', room.automationPaused && 'paused')}><div><b>{room.name}</b><small>{room.automationPaused ? 'Schedules enabled · execution paused' : 'Automation active'}</small></div>{room.automationPaused ? <><StatusBadge phase="paused" /><button className="button primary small" onClick={() => pauseRoom(room.id, false)}>Resume</button></> : <details className="menu-wrap"><summary className="button secondary small">Pause <span aria-hidden="true">▾</span></summary><div className="menu-pop"><button onClick={() => pauseRoom(room.id, true)}>For one hour</button><button onClick={() => pauseRoom(room.id, true)}>Until next schedule</button><button onClick={() => pauseRoom(room.id, true)}>Until I resume</button></div></details>}</article>)}</div></section>
    <section className="section-block"><div className="section-heading"><div><p className="eyebrow">Schedule list</p><h2>Upcoming routines</h2></div><div className="filter-pills"><button className="active">All</button><button>Enabled</button><button>Disabled</button></div></div><div className="schedule-list">{schedules.map((schedule) => <article key={schedule.id} className={!schedule.enabled ? 'disabled' : ''}><div className="schedule-time"><b>{schedule.time}</b><small>Weekdays</small></div><div><b>{schedule.name}</b><small>{schedule.room} · {schedule.action}</small></div><StatusBadge phase={rooms.find((room) => room.name === schedule.room)?.automationPaused ? 'paused' : schedule.enabled ? 'confirmed' : 'stale'} label={rooms.find((room) => room.name === schedule.room)?.automationPaused ? 'Room paused' : schedule.enabled ? 'Enabled' : 'Schedule disabled'} /><Toggle checked={schedule.enabled} onChange={() => {}} label={`${schedule.enabled ? 'Disable' : 'Enable'} ${schedule.name}`} /><button className="icon-button" aria-label={`Edit ${schedule.name}`} onClick={() => setEditor(true)}>···</button></article>)}</div></section>
    {editor && <Modal title="Edit schedule" onClose={() => setEditor(false)}><div className="modal-body"><label className="field"><span>Name</span><input defaultValue="Wind down" /></label><label className="field"><span>Room</span><select><option>Bedroom</option><option>Living Room</option><option>Studio Office</option></select></label><div className="mode-tabs large">{(['fixed', 'sunrise', 'sunset'] as const).map((item) => <button className={mode === item ? 'active' : ''} key={item} onClick={() => setMode(item)}>{item === 'fixed' ? 'Fixed time' : item[0].toUpperCase() + item.slice(1)}</button>)}</div>{mode === 'fixed' ? <label className="field"><span>Time</span><input type="time" defaultValue="22:30" /></label> : <label className="field"><span>Offset</span><select><option>At {mode}</option><option>15 minutes before</option><option>30 minutes before</option><option>15 minutes after</option></select></label>}<fieldset className="day-picker"><legend>Repeat</legend>{['S', 'M', 'T', 'W', 'T2', 'F', 'S2'].map((day) => <button type="button" key={day} aria-pressed={days.includes(day)} className={days.includes(day) ? 'active' : ''} onClick={() => setDays((items) => items.includes(day) ? items.filter((item) => item !== day) : [...items, day])}>{day.replace('2', '')}</button>)}</fieldset><label className="field"><span>Action</span><select><option>Dim to 20%</option><option>Turn on</option><option>Turn off</option><option>Apply a scene</option></select></label><label className="checkbox-row"><input type="checkbox" defaultChecked /><span><b>Schedule enabled</b><small>This is separate from pausing all automation for the room.</small></span></label></div><footer className="modal-actions"><button className="button secondary" onClick={() => setEditor(false)}>Cancel</button><button className="button primary" onClick={() => setEditor(false)}>Save schedule</button></footer></Modal>}
  </>
}

function DevicesView({ devices, setDevices, commands, retryCommand, onOpenLight }: { devices: Device[]; setDevices: React.Dispatch<React.SetStateAction<Device[]>>; commands: Record<string, CommandPhase>; retryCommand: (id: string) => void; onOpenLight: (id: string) => void }) {
  const [scanning, setScanning] = useState(false)
  const scan = () => { setScanning(true); window.setTimeout(() => { setScanning(false); setDevices((items) => items.map((device) => device.id === 'lamp' ? { ...device, connectivity: 'online' } : device)) }, 1200) }
  return <>
    <section className="page-heading"><div><p className="eyebrow">Devices</p><h1>Discovery and local network health</h1><p>Simple recovery first; technical detail when you ask for it.</p></div><button className="button primary" onClick={scan} disabled={scanning}>{scanning ? 'Scanning…' : '↻ Scan for lights'}</button></section>
    <div className="diagnostic-summary"><div className={scanning ? 'scan-pulse active' : 'scan-pulse'}>⌁</div><div><b>{scanning ? 'Querying device state' : 'Local network ready'}</b><span>{scanning ? 'LIFX and Govee LAN discovery in progress…' : `Last scan just now · ${devices.filter((device) => device.connectivity === 'online').length} online · ${devices.filter((device) => device.connectivity !== 'online').length} need attention`}</span></div><StatusBadge phase={scanning ? 'sending' : 'confirmed'} label={scanning ? 'Scanning' : 'Discovery available'} /></div>
    <div className="devices-layout"><section className="section-block"><div className="section-heading"><div><p className="eyebrow">Discovery results</p><h2>Known lights</h2></div><div className="filter-pills"><button className="active">All {devices.length}</button><button>Unassigned 0</button><button>Offline 1</button></div></div><div className="device-table">{devices.map((device) => <article key={device.id}><span className="device-dot" style={{ '--light-color': device.color } as React.CSSProperties} /><div><b>{device.name}</b><small>{device.vendor} · {device.model}</small></div><span>{initialRooms.find((room) => room.id === device.roomId)?.name}</span><StatusBadge phase={commands[device.id] !== 'confirmed' && commands[device.id] ? commands[device.id] : device.connectivity} />{device.connectivity !== 'online' ? <button className="button secondary small" onClick={() => retryCommand(device.id)}>Retry</button> : <button className="text-button" onClick={() => onOpenLight(device.id)}>Inspect</button>}</article>)}</div></section><aside className="diagnostics-panel"><p className="eyebrow">Recovery guidance</p><h2>One device is offline</h2><div className="recovery-steps"><span>1</span><p><b>Check power</b>The Bedroom Ceiling last responded yesterday.</p><span>2</span><p><b>Check the Wi-Fi</b>Avoid guest networks or client isolation.</p><span>3</span><p><b>Rescan</b>Discovery will not change your room assignments.</p></div><button className="button secondary" onClick={scan}>Rescan</button><details><summary>Show technical details</summary><dl><div><dt>Desired state</dt><dd>Off · 55%</dd></div><div><dt>Confirmed state</dt><dd>Off · yesterday</dd></div><div><dt>Discovery</dt><dd>No LAN response</dd></div><div><dt>Network guidance</dt><dd>UDP device-to-device traffic required</dd></div></dl></details><hr /><p className="eyebrow">Activity</p><ul className="activity-list"><li><span>✓</span><p><b>Media Cove confirmed</b>Brightness 64% · just now</p></li><li><span>!</span><p><b>Ceiling unreachable</b>Schedule skipped · 7:00 AM</p></li><li><span>↻</span><p><b>Discovery complete</b>8 known lights · yesterday</p></li></ul></aside></div>
  </>
}

function SettingsView({ demoMode, setDemoMode, restartSetup }: { demoMode: boolean; setDemoMode: (value: boolean) => void; restartSetup: () => void }) {
  const [quiet, setQuiet] = useState(false)
  const [aurora, setAurora] = useState(true)
  const [effectsReduced, setEffectsReduced] = useState(false)
  return <>
    <section className="page-heading"><div><p className="eyebrow">Settings</p><h1>Make the instrument yours</h1><p>Appearance, interaction, privacy, menu bar, and local configuration.</p></div></section>
    <div className="settings-layout"><nav className="settings-nav" aria-label="Settings sections"><button className="active">Appearance</button><button>Interaction</button><button>Menu Bar</button><button>Privacy & Permissions</button><button>Import & Export</button><button>Labs</button></nav><section className="settings-content"><div className="settings-group"><p className="eyebrow">Appearance</p><h2>Aurora Noir</h2><SettingRow title="Quiet Interface" detail="Reduce decorative color and ambient treatments."><Toggle checked={quiet} onChange={setQuiet} label="Quiet Interface" /></SettingRow><SettingRow title="Aurora effects" detail="Show restrained ambient color near active lights."><Toggle checked={aurora} onChange={setAurora} label="Aurora effects" /></SettingRow><SettingRow title="Reduced visual effects" detail="Minimize glow, transforms, and animated transitions."><Toggle checked={effectsReduced} onChange={setEffectsReduced} label="Reduced visual effects" /></SettingRow><SettingRow title="Workspace layout" detail="Choose how device controls use space."><select><option>Automatic</option><option>List</option><option>Grid</option></select></SettingRow><SettingRow title="Interface density" detail="Comfortable or information-dense controls."><select><option>Comfortable</option><option>Compact</option></select></SettingRow></div><div className="settings-group"><p className="eyebrow">Interaction</p><SettingRow title="Confirmation policy" detail="When LumenDesk should read state back from devices."><select><option>Balanced</option><option>Always confirm</option><option>Optimistic</option></select></SettingRow><SettingRow title="Menu-bar scope" detail="Choose the shortcuts shown in the macOS menu bar."><select><option>Favorites</option><option>Active rooms</option><option>All rooms</option></select></SettingRow><SettingRow title="Sunrise and sunset" detail="Local reference times for solar-style schedules."><button className="button secondary small">Configure</button></SettingRow></div><div className="settings-group demo-setting"><div><p className="eyebrow">Safe exploration</p><h2>Demo Mode</h2><p>No physical devices are controlled. Sample rooms, lights, failures, and Segment Studio stay fully interactive.</p></div><div><StatusBadge phase={demoMode ? 'demo' : 'confirmed'} label={demoMode ? 'Demo is active' : 'Live workspace'} /><button className={cx('button', demoMode ? 'secondary' : 'primary')} onClick={() => setDemoMode(!demoMode)}>{demoMode ? 'Return to Live' : 'Enter Demo Mode'}</button></div></div><div className="settings-group"><p className="eyebrow">Setup & data</p><SettingRow title="Guided setup" detail="Review permissions, discovery, naming, and rooms again."><button className="button secondary small" onClick={restartSetup}>Restart setup</button></SettingRow><SettingRow title="Import configuration" detail="Replace local rooms, scenes, favorites, and names."><button className="button secondary small">Import…</button></SettingRow><SettingRow title="Export configuration" detail="Save a private JSON backup on this device."><button className="button secondary small">Export…</button></SettingRow></div></section></div>
  </>
}

function SettingRow({ title, detail, children }: { title: string; detail: string; children: React.ReactNode }) {
  return <div className="setting-row"><div><b>{title}</b><span>{detail}</span></div>{children}</div>
}

function SegmentStudio({ device, onCancel, onApply }: { device: Device; onCancel: () => void; onApply: (segments: Segment[]) => void }) {
  const original = device.segments ?? segmentColors.map((color) => ({ color, brightness: 80 }))
  const [draft, setDraft] = useState<Segment[]>(original.map((segment) => ({ ...segment })))
  const [selected, setSelected] = useState<number[]>([])
  const [paint, setPaint] = useState('#FF5470')
  const [endColor, setEndColor] = useState('#6B7DFF')
  const [brightness, setBrightness] = useState(80)
  const [gradient, setGradient] = useState(false)
  const [livePreview, setLivePreview] = useState(false)
  const [applyConfirm, setApplyConfirm] = useState(false)
  const [applied, setApplied] = useState(false)
  const targets = selected.length ? selected : draft.map((_, index) => index)
  const selectAll = () => setSelected(draft.map((_, index) => index))
  const paintTargets = (color: string) => setDraft((items) => items.map((segment, index) => targets.includes(index) ? { ...segment, color } : segment))
  const setTargetBrightness = (value: number) => { setBrightness(value); setDraft((items) => items.map((segment, index) => targets.includes(index) ? { ...segment, brightness: value } : segment)) }
  const everyOther = () => setSelected(draft.map((_, index) => index).filter((index) => index % 2 === 0))
  const invert = () => setSelected(draft.map((_, index) => index).filter((index) => !selected.includes(index)))
  const shift = (direction: number) => setDraft((items) => items.map((_, index) => items[(index - direction + items.length) % items.length]))
  const blend = () => {
    const indexes = targets.slice().sort((a, b) => a - b)
    const parse = (hex: string) => [1, 3, 5].map((offset) => parseInt(hex.slice(offset, offset + 2), 16))
    const a = parse(paint); const b = parse(endColor)
    setDraft((items) => items.map((segment, index) => { const pos = indexes.indexOf(index); if (pos < 0) return segment; const t = pos / Math.max(1, indexes.length - 1); const channel = a.map((value, i) => Math.round(value + (b[i] - value) * t).toString(16).padStart(2, '0')).join(''); return { ...segment, color: `#${channel}` } }))
  }
  const apply = () => { onApply(draft); setApplyConfirm(false); setApplied(true); window.setTimeout(() => setApplied(false), 1600) }
  const dirty = JSON.stringify(draft) !== JSON.stringify(original)

  return <div className="studio-shell">
    <header className="studio-header"><div><button className="back-button" onClick={onCancel}>‹ {device.name}</button><p className="eyebrow">Govee RGBIC</p><h1>Segment Studio</h1><p>{device.name} · {draft.length} zones · Changes stay in draft until applied</p></div><div className="studio-status"><StatusBadge phase={livePreview ? 'sending' : 'confirmed'} label={livePreview ? 'Live preview · volatile' : dirty ? 'Unsaved draft' : 'Matches light'} /><label className="live-toggle"><span><b>Live Preview</b><small>Temporary on the light</small></span><Toggle checked={livePreview} onChange={setLivePreview} label="Live Preview" /></label></div></header>
    <main className="studio-main"><section className="strip-workbench"><div className="strip-caption"><div><p className="eyebrow">Light layout</p><h2>Paint the strip</h2></div><span>{selected.length ? `${selected.length} selected` : 'Nothing selected · edits affect all zones'}</span></div><div className="segment-strip" role="group" aria-label={`${draft.length} light segments`}>{draft.map((segment, index) => <button key={index} className={selected.includes(index) ? 'selected' : ''} style={{ '--segment-color': segment.color, '--segment-opacity': `${Math.max(.2, segment.brightness / 100)}` } as React.CSSProperties} aria-label={`Segment ${index + 1}, ${selected.includes(index) ? 'selected' : 'not selected'}`} aria-pressed={selected.includes(index)} onClick={() => setSelected((items) => items.includes(index) ? items.filter((item) => item !== index) : [...items, index])}><i /><span>{index + 1}</span></button>)}</div><div className="selection-toolbar" aria-label="Segment selection tools"><button onClick={selectAll}>Select All</button><button onClick={() => setSelected([])}>Select None</button><button onClick={invert}>Invert</button><button onClick={everyOther}>Every Other</button><span /><button onClick={() => shift(-1)} aria-label="Shift layout left">← Shift</button><button onClick={() => shift(1)} aria-label="Shift layout right">Shift →</button></div><div className="preview-legend"><span><i className="selected-sample" />Selected</span><span><i className="preview-sample" />{livePreview ? 'Preview streaming to light' : 'Draft only'}</span></div></section>
      <aside className="studio-tools">
        <section><p className="eyebrow">Paint</p><div className="paint-control"><input type="color" value={paint} onChange={(event) => setPaint(event.target.value)} aria-label="Paint color" /><div><b>{paint.toUpperCase()}</b><small>Current brush</small></div><button className="button primary small" onClick={() => paintTargets(paint)}>Paint selection</button></div><span className="field-label">Swatches & recent</span><div className="studio-swatches">{['#FF5470', '#FF9F4A', '#FFD45C', '#C8FF5B', '#39E6C9', '#62C8FF', '#8B7BFF', '#F06BFF'].map((color) => <button key={color} style={{ background: color }} className={paint === color ? 'active' : ''} aria-label={`Use ${color}`} onClick={() => { setPaint(color); paintTargets(color) }} />)}</div></section>
        <section><p className="eyebrow">Segment brightness</p><label className="large-slider compact"><span>{selected.length ? 'Selection' : 'All zones'}</span><output>{brightness}%</output><input type="range" min="1" max="100" value={brightness} onChange={(event) => setTargetBrightness(Number(event.target.value))} /></label></section>
        <section><div className="tool-heading"><p className="eyebrow">Gradient</p><Toggle checked={gradient} onChange={setGradient} label="Gradient blending" /></div><div className={cx('gradient-tools', !gradient && 'disabled')}><label>End color <input type="color" value={endColor} disabled={!gradient} onChange={(event) => setEndColor(event.target.value)} /></label><div className="gradient-preview" style={{ background: `linear-gradient(90deg, ${paint}, ${endColor})` }} /><button className="button secondary small" onClick={blend} disabled={!gradient}>Blend across selection</button></div></section>
        <section><p className="eyebrow">Presets</p><div className="preset-row"><button onClick={() => setDraft(segmentColors.map((color) => ({ color, brightness: 80 })))}><span className="preset-art rainbow" />Rainbow Flow</button><button onClick={() => setDraft(draft.map((segment, index) => ({ ...segment, color: index % 2 ? '#FFFFFF' : '#FF334F' })))}><span className="preset-art candy" />Candy Cane</button><button><span className="preset-art custom" />Saved presets</button></div></section>
        <details><summary>Device segment count</summary><label className="field"><span>Zones for unknown models</span><input type="number" min="1" max="64" value={draft.length} readOnly /></label></details>
      </aside>
    </main>
    <footer className="studio-footer"><div>{livePreview ? <><StatusBadge phase="sending" label="Preview is temporary" /><span>Cancel restores the opening state.</span></> : <><StatusBadge phase={dirty ? 'applied' : 'confirmed'} label={dirty ? 'Draft changed' : 'No changes'} /><span>Nothing is sent until Apply.</span></>}</div><button className="button secondary" onClick={onCancel}>Cancel</button><button className="button primary" onClick={() => setApplyConfirm(true)} disabled={!dirty}>Apply to Light</button></footer>
    {applyConfirm && <Modal title="Apply this layout to the light?" onClose={() => setApplyConfirm(false)}><div className="modal-body"><div className="apply-preview">{draft.map((segment, index) => <i key={index} style={{ background: segment.color, opacity: segment.brightness / 100 }} />)}</div><p>This makes the painted layout durable for <b>{device.name}</b>. You can undo from the device screen.</p>{livePreview && <div className="info-panel">Live Preview is volatile. Apply converts the current draft into the saved device layout.</div>}</div><footer className="modal-actions"><button className="button secondary" onClick={() => setApplyConfirm(false)}>Keep editing</button><button className="button primary" onClick={apply}>Apply to Light</button></footer></Modal>}
    {applied && <div className="toast" role="status"><span>✓</span><div><b>Layout applied</b><small>Confirmed by {device.name}</small></div></div>}
  </div>
}

function MenuBarController({ devices, scenes, activeEffect, setActiveEffect, runCommand, onClose }: { devices: Device[]; scenes: Scene[]; activeEffect: string | null; setActiveEffect: (id: string | null) => void; runCommand: (id: string, patch: Partial<Device>) => void; onClose: () => void }) {
  const favoriteDevices = devices.filter((device) => device.favorite)
  return <Modal title="Menu-bar controller" onClose={onClose}><div className="menubar-popover"><div className="menubar-title"><div><span className="brand-mark small">◒</span><span><b>LumenDesk</b><small>{devices.filter((device) => device.connectivity === 'online').length} of {devices.length} online</small></span></div><button className="icon-button">↻</button></div>{devices.some((device) => device.connectivity === 'offline') && <div className="menubar-alert"><StatusBadge phase="offline" label="1 device offline" /><button className="text-button">Details</button></div>}<section><p className="eyebrow">Favorites</p>{favoriteDevices.map((device) => <div className="menubar-row" key={device.id}><span className="favorite-orb" style={{ background: device.color }} /><div><b>{device.name}</b><small>{device.brightness}% · {device.vendor}</small></div><Toggle checked={device.on} onChange={(on) => runCommand(device.id, { on })} label={`Toggle ${device.name}`} /></div>)}</section><section><p className="eyebrow">Scenes</p><div className="menubar-scene-row">{scenes.filter((scene) => scene.favorite).map((scene) => <button key={scene.id}><span className="mini-palette">{scene.colors.map((color) => <i key={color} style={{ background: color }} />)}</span>{scene.name}</button>)}</div></section>{activeEffect && <div className="menubar-effect"><StatusBadge phase="running" /><span>{effects.find((effect) => effect.id === activeEffect)?.name}</span><button className="button secondary small" onClick={() => setActiveEffect(null)}>Stop</button></div>}<footer><button className="text-button">Open LumenDesk</button><button className="text-button">Settings</button></footer></div></Modal>
}

export default function App() {
  const [setup, setSetup] = useState(true)
  const [demoMode, setDemoMode] = useState(false)
  const [route, setRoute] = useState<Route>('home')
  const [previousRoute, setPreviousRoute] = useState<Route>('home')
  const [rooms, setRooms] = useState(initialRooms)
  const [devices, setDevices] = useState(initialDevices)
  const [scenes, setScenes] = useState(initialScenes)
  const [commands, setCommands] = useState<Record<string, CommandPhase>>({})
  const [selectedRoom, setSelectedRoom] = useState('living')
  const [selectedLight, setSelectedLight] = useState('cove')
  const [activeEffect, setActiveEffect] = useState<string | null>(null)
  const [menuBarOpen, setMenuBarOpen] = useState(false)
  const [announcement, setAnnouncement] = useState('')

  const navigate = (next: Route) => { setPreviousRoute(route); setRoute(next); window.scrollTo({ top: 0, behavior: 'smooth' }) }
  const runCommand = (id: string, patch: Partial<Device>) => {
    const device = devices.find((item) => item.id === id)
    if (!device) return
    setDevices((items) => items.map((item) => item.id === id ? { ...item, ...patch } : item))
    setCommands((items) => ({ ...items, [id]: 'sending' }))
    setAnnouncement(`Sending command to ${device.name}`)
    window.setTimeout(() => {
      if (device.connectivity === 'offline' || device.connectivity === 'stale') {
        setCommands((items) => ({ ...items, [id]: 'failed' }))
        setAnnouncement(`Command failed for ${device.name}. Retry is available.`)
      } else {
        setCommands((items) => ({ ...items, [id]: 'applied' }))
        setAnnouncement(`Applied locally to ${device.name}`)
        window.setTimeout(() => { setCommands((items) => ({ ...items, [id]: 'confirmed' })); setAnnouncement(`Confirmed by ${device.name}`) }, 650)
      }
    }, 650)
  }
  const retryCommand = (id: string) => {
    const device = devices.find((item) => item.id === id)
    if (!device) return
    setDevices((items) => items.map((item) => item.id === id ? { ...item, connectivity: 'online' } : item))
    setCommands((items) => ({ ...items, [id]: 'sending' }))
    setAnnouncement(`Retrying ${device.name}`)
    window.setTimeout(() => { setCommands((items) => ({ ...items, [id]: 'confirmed' })); setAnnouncement(`${device.name} is online and confirmed`) }, 900)
  }
  const openRoom = (id: string) => { setSelectedRoom(id); navigate('room') }
  const openLight = (id: string) => { setSelectedLight(id); navigate('light') }
  const device = devices.find((item) => item.id === selectedLight) ?? devices[0]
  const room = rooms.find((item) => item.id === selectedRoom) ?? rooms[0]
  const pageTitle = navItems.find((item) => item.id === route)?.label ?? (route === 'room' ? room.name : route === 'light' ? device.name : 'Segment Studio')

  if (setup) return <Onboarding onFinish={() => { setSetup(false); setRoute('home') }} onDemo={() => { setDemoMode(true); setSetup(false); setRoute('home') }} />
  if (route === 'segment') return <SegmentStudio device={device} onCancel={() => setRoute('light')} onApply={(segments) => { setDevices((items) => items.map((item) => item.id === device.id ? { ...item, segments, color: segments[0]?.color ?? item.color } : item)); setCommands((items) => ({ ...items, [device.id]: 'confirmed' })) }} />

  return <div className="app-shell">
    <a href="#main-content" className="skip-link">Skip to content</a>
    <aside className="sidebar"><div className="brand-lockup"><span className="brand-mark">◒</span><span>LumenDesk</span></div><nav aria-label="Primary navigation">{navItems.map((item) => <button key={item.id} className={route === item.id ? 'active' : ''} onClick={() => navigate(item.id)}><span aria-hidden="true">{item.icon}</span>{item.label}{item.id === 'devices' && devices.some((device) => device.connectivity === 'offline') && <i className="nav-alert" aria-label="Device attention needed" />}</button>)}</nav><div className="sidebar-bottom"><div className="local-chip"><span>⌁</span><div><b>Local connection</b><small>{devices.filter((d) => d.connectivity === 'online').length} devices online</small></div></div><button className="profile-button" onClick={() => navigate('settings')}><span>SV</span><span><b>Private workspace</b><small>No account required</small></span></button></div></aside>
    <div className="workspace"><header className="topbar"><div><button className="mobile-brand" onClick={() => navigate('home')} aria-label="LumenDesk Home"><span className="brand-mark small">◒</span></button><div><p className="eyebrow">Workspace</p><b>{pageTitle}</b></div></div><div className="topbar-actions"><StatusBadge phase={devices.some((item) => item.connectivity === 'offline') ? 'offline' : 'online'} label={`${devices.filter((item) => item.connectivity === 'online').length}/${devices.length} online`} /><button className="button secondary small" onClick={() => { setAnnouncement('Scanning for local lights'); window.setTimeout(() => setAnnouncement('Scan complete. Eight known lights.'), 900) }}>↻ Scan</button><button className="icon-button menubar-button" aria-label="Open menu-bar controller simulation" onClick={() => setMenuBarOpen(true)}>◒</button></div></header>
      <main id="main-content" className="page-content">
        {route === 'home' && <HomeView rooms={rooms} devices={devices} commands={commands} scenes={scenes} activeEffect={activeEffect} demoMode={demoMode} onOpenRoom={openRoom} onOpenLight={openLight} onNavigate={navigate} runCommand={runCommand} retryCommand={retryCommand} setDevices={setDevices} />}
        {route === 'room' && <RoomView room={room} devices={devices.filter((item) => item.roomId === room.id)} commands={commands} runCommand={runCommand} onOpenLight={openLight} onBack={() => setRoute('home')} onPause={() => setRooms((items) => items.map((item) => item.id === room.id ? { ...item, automationPaused: !item.automationPaused } : item))} />}
        {route === 'light' && <LightView device={device} command={commands[device.id] ?? 'confirmed'} runCommand={runCommand} retryCommand={retryCommand} onBack={() => setRoute(previousRoute === 'room' ? 'room' : 'home')} onSegment={() => navigate('segment')} />}
        {route === 'library' && <LibraryView scenes={scenes} setScenes={setScenes} activeEffect={activeEffect} setActiveEffect={setActiveEffect} />}
        {route === 'automation' && <AutomationView rooms={rooms} setRooms={setRooms} />}
        {route === 'devices' && <DevicesView devices={devices} setDevices={setDevices} commands={commands} retryCommand={retryCommand} onOpenLight={openLight} />}
        {route === 'settings' && <SettingsView demoMode={demoMode} setDemoMode={setDemoMode} restartSetup={() => setSetup(true)} />}
      </main>
    </div>
    <nav className="mobile-tabbar" aria-label="Mobile navigation">{navItems.filter((item) => item.id !== 'settings').map((item) => <button key={item.id} className={route === item.id ? 'active' : ''} onClick={() => navigate(item.id)}><span>{item.icon}</span>{item.label}</button>)}</nav>
    <div className="sr-only" aria-live="polite">{announcement}</div>
    {menuBarOpen && <MenuBarController devices={devices} scenes={scenes} activeEffect={activeEffect} setActiveEffect={setActiveEffect} runCommand={runCommand} onClose={() => setMenuBarOpen(false)} />}
  </div>
}
