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

      const at = firstOccurrence(schedule, previous, now)
      if (at) decisions.push({ room, schedule, at })
    }
  }

  return decisions
}

/** First matching minute in (previous, now], preserving local-time/DST stepping. */
function firstOccurrence(schedule, previous, now) {
  const cursor = new Date(previous.getTime())
  cursor.setSeconds(0, 0)
  cursor.setMinutes(cursor.getMinutes() + 1)

  // Do not replace this with elapsed milliseconds: setMinutes follows the
  // existing local-clock behavior across daylight-saving transitions.
  while (cursor <= now) {
    const matchesDay = (schedule.weekdays ?? []).includes(weekdayOf(cursor))
    const matchesTime =
      cursor.getHours() === schedule.hour && cursor.getMinutes() === schedule.minute
    if (matchesDay && matchesTime && cursor > previous) {
      return new Date(cursor.getTime()) // one firing per window, however long the gap
    }
    cursor.setMinutes(cursor.getMinutes() + 1)
  }
  return null
}

const DIM_LEVELS = new Map([
  ['dim10', 10],
  ['dim25', 25],
  ['dim50', 50],
  ['dim75', 75],
])

/** Translate a schedule action into a fresh command list for its room. */
export function commandsFor(action) {
  switch (action) {
    case 'turnOn':
      return [{ kind: 'power', on: true }]
    case 'turnOff':
      return [{ kind: 'power', on: false }]
    default: {
      const value = DIM_LEVELS.get(action)
      return value === undefined
        ? []
        : [{ kind: 'power', on: true }, { kind: 'brightness', value }]
    }
  }
}

export const ACTIONS = ['turnOn', 'turnOff', 'dim10', 'dim25', 'dim50', 'dim75', 'applyScene']
