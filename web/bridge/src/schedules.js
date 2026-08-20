// Pure schedule evaluation, mirroring the native ScheduleEngine: it returns
// decisions and never touches a device itself, so it can be tested with an
// injected clock instead of by waiting.

/** Weekday numbers match the native model: 1 = Sunday … 7 = Saturday. */
export function weekdayOf(date) {
  return date.getDay() + 1
}

export function minutesOfDay(date) {
  return date.getHours() * 60 + date.getMinutes()
}

/**
 * Decide which schedules should fire in the window (previous, now].
 * Using a half-open window means a restart cannot double-fire an entry, and a
 * tick that arrives late still catches what it slept through.
 */
export function due({ rooms, previous, now }) {
  if (!previous || now <= previous) return []
  const decisions = []

  for (const room of rooms) {
    for (const schedule of room.schedules ?? []) {
      if (!schedule.isEnabled) continue

      // Walk each minute boundary the window crossed, so a long gap (a laptop
      // waking from sleep) still runs what it missed, once.
      const cursor = new Date(previous.getTime())
      cursor.setSeconds(0, 0)
      cursor.setMinutes(cursor.getMinutes() + 1)

      while (cursor <= now) {
        const matchesDay = (schedule.weekdays ?? []).includes(weekdayOf(cursor))
        const matchesTime =
          cursor.getHours() === schedule.hour && cursor.getMinutes() === schedule.minute
        if (matchesDay && matchesTime && cursor > previous) {
          decisions.push({ room, schedule, at: new Date(cursor.getTime()) })
          break // one firing per window, however long the gap
        }
        cursor.setMinutes(cursor.getMinutes() + 1)
      }
    }
  }

  return decisions
}

/** Translate a schedule action into the commands its room's lights should get. */
export function commandsFor(action) {
  switch (action) {
    case 'turnOn':
      return [{ kind: 'power', on: true }]
    case 'turnOff':
      return [{ kind: 'power', on: false }]
    case 'dim10':
      return [{ kind: 'power', on: true }, { kind: 'brightness', value: 10 }]
    case 'dim25':
      return [{ kind: 'power', on: true }, { kind: 'brightness', value: 25 }]
    case 'dim50':
      return [{ kind: 'power', on: true }, { kind: 'brightness', value: 50 }]
    case 'dim75':
      return [{ kind: 'power', on: true }, { kind: 'brightness', value: 75 }]
    default:
      return []
  }
}

export const ACTIONS = ['turnOn', 'turnOff', 'dim10', 'dim25', 'dim50', 'dim75', 'applyScene']
