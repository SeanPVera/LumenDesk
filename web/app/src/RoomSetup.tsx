import { useEffect, useId, useRef, useState } from 'react'
import type { Device, DiscoveryResponse, Room } from './bridge'
import { DiscoveryStatus } from './DiscoveryStatus'

const STEPS = ['Find lights', 'Create room', 'Assign lights', 'Try controls']

export interface RoomSetupProps {
  /** Keep this component mounted while closed so paused drafts survive. */
  open: boolean
  devices: Device[]
  rooms: Room[]
  scanning: boolean
  discovery: DiscoveryResponse | null
  answeredCount: number | null
  discoveryError?: string | null
  onScan: () => Promise<void>
  onCreateRoom: (name: string) => Promise<Room | null>
  onAssign: (device: Device, roomID: string) => Promise<boolean>
  onPower: (device: Device, on: boolean) => Promise<boolean>
  onBrightness: (device: Device, value: number) => Promise<boolean>
  onPairShapes: (host: string, port: number) => Promise<Device | null>
  onDone: (roomID: string) => void
  onCancel: () => void
}

export function RoomSetup({ open, devices, rooms, scanning, discovery, answeredCount, discoveryError,
  onScan, onCreateRoom, onAssign, onPower, onBrightness, onPairShapes, onDone, onCancel }: RoomSetupProps) {
  const [stage, setStage] = useState(0)
  const [name, setName] = useState('')
  const [savedRoom, setSavedRoom] = useState<Room | null>(null)
  const [existingID, setExistingID] = useState('')
  const [selectedIDs, setSelectedIDs] = useState<string[]>([])
  const [assignedIDs, setAssignedIDs] = useState<string[]>([])
  const [targetID, setTargetID] = useState('')
  const [level, setLevel] = useState(50)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [pairing, setPairing] = useState(false)
  const [host, setHost] = useState('')
  const [port, setPort] = useState('16021')
  const pending = useRef(false)
  const confirmedRoom = useRef<Room | null>(null)
  const heading = useRef<HTMLHeadingElement>(null)
  const titleID = useId()
  const nameID = useId()
  const levelID = useId()
  const canonicalRoom = savedRoom ? rooms.find(candidate => candidate.id === savedRoom.id) : undefined
  // A successful create response or room collection confirms the room. Once
  // confirmed, only its current record is valid.
  const room = canonicalRoom ?? (savedRoom && confirmedRoom.current?.id !== savedRoom.id ? savedRoom : null)
  const duplicate = rooms.find(candidate => candidate.name.trim().toLocaleLowerCase() === name.trim().toLocaleLowerCase())
  const roomDevices = room ? devices.filter(device => device.roomID === room.id || assignedIDs.includes(device.id) || room.lightIDs.includes(device.id)) : []
  const target = roomDevices.find(device => device.id === targetID) ?? roomDevices.find(device => device.reachable && !device.needsPairing) ?? roomDevices[0]

  useEffect(() => {
    if (open) heading.current?.focus()
  }, [open, stage])

  useEffect(() => {
    if (target) setLevel(target.brightness)
  }, [target?.id])

  useEffect(() => {
    if (!savedRoom) return
    if (canonicalRoom) {
      confirmedRoom.current = canonicalRoom
      return
    }
    const deleted = confirmedRoom.current
    if (deleted?.id !== savedRoom.id || busy) return
    // Let an in-flight assignment or command settle before recovering. Its
    // completion must not advance the wizard after this reset.
    confirmedRoom.current = null
    setName(deleted.name)
    setSavedRoom(null)
    setExistingID('')
    setSelectedIDs(previous => [...new Set([...previous, ...assignedIDs, ...deleted.lightIDs])])
    setAssignedIDs([])
    setTargetID('')
    setMessage(null)
    setProblem('This room was deleted. Create a new room or choose an existing room to continue. Your light choices are kept.')
    setStage(1)
  }, [savedRoom, canonicalRoom, busy, assignedIDs])

  const changeStage = (next: number) => {
    setProblem(null)
    setMessage(null)
    setStage(next)
  }

  const perform = async (action: () => Promise<void>) => {
    if (pending.current) return
    pending.current = true
    setBusy(true)
    setProblem(null)
    setMessage(null)
    try {
      await action()
    } catch (error) {
      setProblem(error instanceof Error ? error.message : String(error))
    } finally {
      pending.current = false
      setBusy(false)
    }
  }

  const create = () => perform(async () => {
    if (!name.trim() || duplicate) return
    const created = await onCreateRoom(name.trim())
    if (!created) {
      setProblem('The room could not be saved. Your name is kept here; try again.')
      return
    }
    // The parent adopts a successful create before refreshing its collection.
    // That refresh may already report a deletion made by another client.
    confirmedRoom.current = created
    setSavedRoom(created)
    changeStage(2)
  })

  const assign = () => perform(async () => {
    if (!room) return
    const selected = devices.filter(device => selectedIDs.includes(device.id))
    if (!selected.length) return
    const results = await Promise.all(selected.map(async device => {
      if (assignedIDs.includes(device.id) || device.roomID === room.id || room.lightIDs.includes(device.id)) return true
      try { return await onAssign(device, room.id) } catch { return false }
    }))
    const succeeded = selected.filter((_, index) => results[index]).map(device => device.id)
    setAssignedIDs(previous => [...new Set([...previous, ...succeeded])])
    const failed = results.filter(result => !result).length
    if (failed) {
      setProblem(`${failed} light${failed === 1 ? '' : 's'} could not be assigned. Saved assignments are kept; try again to add the remaining lights.`)
      return
    }
    changeStage(3)
  })

  const testCommand = (action: 'on' | 'off' | 'brightness') => perform(async () => {
    if (!target || !target.reachable || target.needsPairing) return
    const succeeded = action === 'brightness' ? await onBrightness(target, level) : await onPower(target, action === 'on')
    if (!succeeded) {
      setProblem('The command could not be sent. Check the light’s connection and try again.')
      return
    }
    setMessage(`${action === 'brightness' ? `${level}% brightness` : action === 'on' ? 'On' : 'Off'} request sent to ${target.name}. Check that the light responds.`)
  })

  const finish = () => {
    if (!room || busy) return
    const completedID = room.id
    setStage(0)
    setName('')
    setSavedRoom(null)
    confirmedRoom.current = null
    setExistingID('')
    setSelectedIDs([])
    setAssignedIDs([])
    setTargetID('')
    setProblem(null)
    setMessage(null)
    setPairing(false)
    onDone(completedID)
  }

  if (!open) return null

  return <section className="panel room-setup" aria-labelledby={titleID}>
    <div className="card-head">
      <div>
        <p className="note">Set up a room · Step {stage + 1} of {STEPS.length}</p>
        <h2 id={titleID} ref={heading} tabIndex={-1}>{STEPS[stage]}</h2>
      </div>
      <button type="button" className="ghost" disabled={busy || scanning} onClick={onCancel}>Pause setup</button>
    </div>
    <ol className="setup-progress" aria-label="Room setup progress">
      {STEPS.map((step, index) => <li key={step} aria-current={stage === index ? 'step' : undefined}>{step}</li>)}
    </ol>
    {problem && <p className="error" role="alert">{problem}</p>}
    {message && <p role="status">{message}</p>}

    {stage === 0 && <>
      <DiscoveryStatus scanning={scanning} result={discovery} answeredCount={answeredCount} problem={discoveryError}
        onPair={() => setPairing(true)} />
      <div className="setup-actions">
        <button type="button" className="primary" disabled={scanning || busy} onClick={onScan}>{scanning ? 'Searching…' : 'Find lights'}</button>
        <button type="button" disabled={scanning || busy || devices.length === 0} onClick={() => changeStage(1)}>Continue to room</button>
      </div>
      <p className="note">{devices.length} known light{devices.length === 1 ? '' : 's'} · {devices.filter(device => device.reachable && !device.needsPairing).length} available for control.</p>
      {devices.length > 0 && <ul className="rows" aria-label="Found lights">{devices.map(device => <li className="row" key={device.id}>
        <strong className="row-action">{device.name}</strong><span className={`badge ${device.brand}`}>{device.brand.toUpperCase()}</span>
        <span>{device.needsPairing ? 'Pair again' : device.reachable ? 'Online' : 'Offline'}</span>
      </li>)}</ul>}
      <details open={pairing} onToggle={event => setPairing(event.currentTarget.open)}>
        <summary>Pair a Nanoleaf wall</summary>
        <p>Find the controller’s IP address in your router’s connected devices. Hold its power button for 5–7 seconds until the LED flashes, then pair within 30 seconds.</p>
        <form className="inline-form" onSubmit={event => {
          event.preventDefault()
          void perform(async () => {
            const paired = await onPairShapes(host.trim(), Number(port))
            if (!paired) { setProblem('Pairing failed. Your controller address is kept here; open its pairing window and try again.'); return }
            setMessage(`Paired ${paired.name}. Continue to create a room.`)
            setHost('')
          })
        }}>
          <label>Controller address<input type="text" placeholder="192.168.1.40" autoComplete="off" spellCheck={false}
            value={host} onChange={event => setHost(event.target.value)} disabled={busy} required /></label>
          <label>Port<input type="number" min="1" max="65535" value={port} onChange={event => setPort(event.target.value)} disabled={busy} required /></label>
          <button type="submit" disabled={busy || scanning || !host.trim() || !Number.isInteger(Number(port)) || Number(port) < 1 || Number(port) > 65535}>{busy ? 'Pairing…' : 'Pair wall'}</button>
        </form>
      </details>
    </>}

    {stage === 1 && <>
      <p>Give this group of lights a name. You’ll use the room for lighting controls, scenes and schedules.</p>
      {savedRoom ? <>
        <p><strong>{room?.name}</strong> is saved. Continue to choose its lights.</p>
        <button type="button" className="primary" onClick={() => changeStage(2)}>Continue to lights</button>
      </> : <>
        <form className="inline-form" onSubmit={event => { event.preventDefault(); void create() }}>
          <label htmlFor={nameID}>Room name</label>
          <input id={nameID} type="text" value={name} onChange={event => setName(event.target.value)} placeholder="e.g. Living room" maxLength={60} disabled={busy} required />
          <button type="submit" className="primary" disabled={busy || !name.trim() || Boolean(duplicate)}>{busy ? 'Creating…' : 'Create room'}</button>
        </form>
        {duplicate && <p className="note">A room named {duplicate.name} already exists. Choose it below or enter a different name.</p>}
        {rooms.length > 0 && <div className="inline-form">
          <label>Or use an existing room<select value={existingID} onChange={event => setExistingID(event.target.value)} disabled={busy}>
            <option value="">Choose a room…</option>{rooms.map(candidate => <option key={candidate.id} value={candidate.id}>{candidate.name}</option>)}
          </select></label>
          <button type="button" disabled={busy || !rooms.some(candidate => candidate.id === existingID)} onClick={() => {
            const existing = rooms.find(candidate => candidate.id === existingID)
            if (existing) { setSavedRoom(existing); changeStage(2) }
          }}>Use room</button>
        </div>}
      </>}
      <button type="button" className="ghost" disabled={busy} onClick={() => changeStage(0)}>Back to lights</button>
    </>}

    {stage === 2 && room && <>
      <p>Choose the lights for <strong>{room.name}</strong>. Lights in another room will move here when you save.</p>
      <ul className="rows">{devices.map(device => {
        const alreadyAssigned = assignedIDs.includes(device.id) || device.roomID === room.id || room.lightIDs.includes(device.id)
        return <li className="row" key={device.id}>
          <label className="row-toggle"><input type="checkbox" checked={alreadyAssigned || selectedIDs.includes(device.id)} disabled={busy || alreadyAssigned}
            onChange={event => setSelectedIDs(previous => event.target.checked ? [...previous, device.id] : previous.filter(id => id !== device.id))} />
            <span>{device.name}</span></label>
          <span className="row-days">{alreadyAssigned ? 'Added to this room' : rooms.find(candidate => candidate.id === device.roomID)?.name ?? 'No room'}</span>
          {(!device.reachable || device.needsPairing) && <span className="warn">{device.needsPairing ? 'Pair again before controlling' : 'Offline; controls need a connection'}</span>}
        </li>
      })}</ul>
      <div className="setup-actions">
        <button type="button" className="ghost" disabled={busy} onClick={() => changeStage(1)}>Back to room</button>
        {selectedIDs.some(id => devices.some(device => device.id === id))
          ? <button type="button" className="primary" disabled={busy} onClick={() => void assign()}>{busy ? 'Saving assignments…' : 'Save lights and continue'}</button>
          : <button type="button" className="primary" disabled={busy || roomDevices.length === 0} onClick={() => changeStage(3)}>Continue with room’s lights</button>}
      </div>
    </>}

    {stage === 3 && room && <>
      <p><strong>{room.name}</strong> is ready with {roomDevices.length} light{roomDevices.length === 1 ? '' : 's'}. Try a control below and check the light itself, or open the room now.</p>
      {roomDevices.length > 0 ? <>
        <label>Light to try<select value={target?.id ?? ''} onChange={event => { setTargetID(event.target.value); setMessage(null) }} disabled={busy}>
          {roomDevices.map(device => <option key={device.id} value={device.id}>{device.name}{!device.reachable ? ' (offline)' : device.needsPairing ? ' (pair again)' : ''}</option>)}
        </select></label>
        <fieldset className="workspace-controls" disabled={busy || !target?.reachable || target.needsPairing} aria-label="Try lighting controls">
          <div className="setup-actions">
            <button type="button" onClick={() => void testCommand('on')}>Turn on</button>
            <button type="button" onClick={() => void testCommand('off')}>Turn off</button>
          </div>
          <label htmlFor={levelID}>Brightness <output>{level}%</output></label>
          <input id={levelID} type="range" min="0" max="100" step="1" value={level} onChange={event => setLevel(Number(event.target.value))} />
          <button type="button" onClick={() => void testCommand('brightness')}>Apply brightness</button>
        </fieldset>
        {(!target?.reachable || target.needsPairing) && <p className="note">This light needs to reconnect or pair before it can be controlled. You can still open the room.</p>}
      </> : <p className="note">The assigned lights are no longer listed. Go back to choose lights or open the room and search again.</p>}
      <div className="setup-actions">
        <button type="button" className="ghost" disabled={busy} onClick={() => changeStage(2)}>Back to assignments</button>
        <button type="button" className="primary" disabled={busy} onClick={finish}>Done, open room</button>
      </div>
    </>}
  </section>
}
