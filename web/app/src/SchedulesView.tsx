import { useRef, useState } from 'react'
import type { Room, Scene, Schedule, ScheduleAction } from './bridge'

export const ACTION_LABELS: Record<ScheduleAction, string> = {
  turnOn: 'Turn on',
  turnOff: 'Turn off',
  dim10: 'Dim to 10%',
  dim25: 'Dim to 25%',
  dim50: 'Dim to 50%',
  dim75: 'Dim to 75%',
  applyScene: 'Apply scene',
}

// The bridge and the native scheduler both use Sunday = 1, Saturday = 7.
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const clockTime = (schedule: Schedule) => `${String(schedule.hour).padStart(2, '0')}:${String(schedule.minute).padStart(2, '0')}`

type UpdateSchedule = (roomID: string, scheduleID: string, patch: Partial<Schedule>) => Promise<boolean>
type DeleteSchedule = (roomID: string, scheduleID: string) => Promise<boolean>

export function AutomationView({ rooms, scenes, onAdd, onUpdate, onDelete }: {
  rooms: Room[]
  scenes: Scene[]
  onAdd: (roomID: string, entry: Partial<Schedule>) => Promise<boolean>
  onUpdate: UpdateSchedule
  onDelete: DeleteSchedule
}) {
  if (rooms.length === 0) return <div className="panel">
    <h2>Create a room first</h2>
    <p>Schedules act on a room's lights. Open <strong>Room</strong> to create a room and assign lights.</p>
  </div>

  return <section>
    <p className="note wide-note">
      Schedules run in the bridge, whether or not this page is open, as long as the bridge is running.
      Times use the bridge computer's local time zone.
    </p>
    {rooms.map(room => <div className="group" key={room.id}>
      <h2 className="group-title">{room.name}<span className="count">{room.schedules.length}</span></h2>
      {room.lightIDs.length === 0 && <p className="note">Assign lights to this room before its lighting schedules can run.</p>}
      <ul className="rows">
        {room.schedules.map(schedule => <ScheduleRow key={schedule.id} room={room} schedule={schedule}
          scenes={scenes} onUpdate={onUpdate} onDelete={onDelete} />)}
      </ul>
      <ScheduleForm room={room} scenes={scenes} onSave={entry => onAdd(room.id, entry)} />
    </div>)}
  </section>
}

function ScheduleRow({ room, schedule, scenes, onUpdate, onDelete }: {
  room: Room
  schedule: Schedule
  scenes: Scene[]
  onUpdate: UpdateSchedule
  onDelete: DeleteSchedule
}) {
  const [editing, setEditing] = useState(false)
  const [working, setWorking] = useState<'toggle' | 'delete' | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const pending = useRef(false)
  const scene = scenes.find(item => item.id === schedule.sceneID)
  const description = `${ACTION_LABELS[schedule.action]} at ${clockTime(schedule)} in ${room.name}`

  const change = async (operation: 'toggle' | 'delete', action: () => Promise<boolean>) => {
    if (pending.current) return
    pending.current = true
    setWorking(operation)
    setProblem(null)
    try {
      if (!await action()) setProblem(operation === 'delete'
        ? 'Schedule was not deleted. Try again.'
        : 'Schedule was not changed. Try again.')
    } catch (error) {
      setProblem(error instanceof Error ? error.message : 'Schedule was not changed. Try again.')
    } finally {
      pending.current = false
      setWorking(null)
    }
  }

  return <li className={`schedule-entry${schedule.isEnabled ? '' : ' muted'}`}>
    <div className="row">
      <label className="row-toggle">
        <input type="checkbox" checked={schedule.isEnabled} disabled={Boolean(working) || editing}
          aria-label={`Enable ${description}`}
          onChange={event => { void change('toggle', () => onUpdate(room.id, schedule.id, { isEnabled: event.target.checked })) }} />
      </label>
      <strong className="row-time">{clockTime(schedule)}</strong>
      <span className="row-action">{ACTION_LABELS[schedule.action]}{schedule.action === 'applyScene' && ` — ${scene?.name ?? 'missing scene'}`}</span>
      <span className="row-days">{schedule.weekdays.length === 7 ? 'Every day' : schedule.weekdays.map(day => DAYS[day - 1]).join(' ')}</span>
      <button type="button" className="ghost" disabled={Boolean(working) || editing} aria-label={`Edit ${description}`}
        onClick={() => { setProblem(null); setEditing(true) }}>Edit</button>
      <button type="button" className="ghost" disabled={Boolean(working) || editing} aria-label={`Delete ${description}`}
        onClick={() => { void change('delete', () => onDelete(room.id, schedule.id)) }}>
        {working === 'delete' ? 'Deleting…' : 'Delete'}
      </button>
    </div>
    {working === 'toggle' && <p className="note" role="status">Updating schedule…</p>}
    {problem && <p className="error" role="alert">{problem}</p>}
    {editing && <ScheduleForm room={room} scenes={scenes} schedule={schedule}
      onSave={patch => onUpdate(room.id, schedule.id, patch)} onCancel={() => setEditing(false)}
      onSaved={() => setEditing(false)} />}
  </li>
}

function ScheduleForm({ room, scenes, schedule, onSave, onCancel, onSaved }: {
  room: Room
  scenes: Scene[]
  schedule?: Schedule
  onSave: (entry: Partial<Schedule>) => Promise<boolean>
  onCancel?: () => void
  onSaved?: () => void
}) {
  const [time, setTime] = useState(schedule ? clockTime(schedule) : '07:30')
  const [action, setAction] = useState<ScheduleAction>(schedule?.action ?? 'turnOn')
  const [sceneID, setSceneID] = useState(schedule?.sceneID ?? '')
  const [weekdays, setWeekdays] = useState<number[]>(schedule ? [...schedule.weekdays] : [1, 2, 3, 4, 5, 6, 7])
  const [saving, setSaving] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const pending = useRef(false)
  const validScene = scenes.some(scene => scene.id === sceneID)
  const validTime = /^([01]\d|2[0-3]):[0-5]\d$/.test(time)
  const invalid = !validTime || weekdays.length === 0 || (action === 'applyScene' && !validScene)
  const context = schedule ? `Edit schedule for ${room.name}` : `Schedule for ${room.name}`

  const toggleDay = (day: number) => {
    setWeekdays(days => days.includes(day) ? days.filter(item => item !== day) : [...days, day].sort((a, b) => a - b))
    setProblem(null)
  }

  return <form className={`inline-form schedule-form${schedule ? ' schedule-edit' : ''}`}
    aria-label={context} aria-busy={saving} onSubmit={async event => {
      event.preventDefault()
      if (pending.current || invalid) return
      pending.current = true
      setSaving(true)
      setProblem(null)
      const [hour, minute] = time.split(':').map(Number)
      try {
        if (await onSave({ hour, minute, action, weekdays, sceneID: action === 'applyScene' ? sceneID : null })) {
          onSaved?.()
        } else {
          setProblem(`Schedule was not ${schedule ? 'saved' : 'added'}. Your changes are ready to retry.`)
        }
      } catch (error) {
        setProblem(error instanceof Error ? error.message : 'Schedule was not saved. Try again.')
      } finally {
        pending.current = false
        setSaving(false)
      }
    }}>
    <input type="time" aria-label={`${schedule ? 'Edit schedule' : 'Schedule'} time for ${room.name}`}
      value={time} onChange={event => { setTime(event.target.value); setProblem(null) }} disabled={saving} required />
    <select aria-label={`${schedule ? 'Edit schedule' : 'Schedule'} action for ${room.name}`} value={action}
      onChange={event => { setAction(event.target.value as ScheduleAction); setProblem(null) }} disabled={saving}>
      {(Object.keys(ACTION_LABELS) as ScheduleAction[]).map(value => <option key={value} value={value}>{ACTION_LABELS[value]}</option>)}
    </select>
    {action === 'applyScene' && <select aria-label={`${schedule ? 'Edit schedule' : 'Schedule'} scene for ${room.name}`}
      value={sceneID} onChange={event => { setSceneID(event.target.value); setProblem(null) }} disabled={saving} required>
      <option value="">Choose a scene…</option>
      {sceneID && !validScene && <option value={sceneID} disabled>Missing scene — choose another</option>}
      {scenes.map(scene => <option key={scene.id} value={scene.id}>{scene.name}</option>)}
    </select>}
    <div className="days" role="group" aria-label={`${context} days`}>
      {DAYS.map((label, index) => <button key={label} type="button"
        className={`chip day${weekdays.includes(index + 1) ? ' active' : ''}`} aria-pressed={weekdays.includes(index + 1)}
        disabled={saving} onClick={() => toggleDay(index + 1)}>{label}</button>)}
    </div>
    {weekdays.length === 0 && <p className="note">Choose at least one day.</p>}
    {action === 'applyScene' && !validScene && <p className="note">Choose an available scene before saving.</p>}
    <button type="submit" disabled={saving || invalid}>{saving ? (schedule ? 'Saving…' : 'Adding…') : (schedule ? 'Save schedule' : 'Add schedule')}</button>
    {onCancel && <button type="button" className="ghost" disabled={saving} onClick={onCancel}>Cancel</button>}
    {problem && <p className="error" role="alert">{problem}</p>}
  </form>
}
