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

      const at = latestOccurrence(schedule, previous, now)
      if (at) decisions.push({ room, schedule, at })
    }
  }

  // Insertion order says nothing about which action should leave a room in
  // its final state after sleep: an older off must precede a newer on.
  return decisions.sort((a, b) => a.at - b.at)
}

/** Latest matching minute in (previous, now], preserving local-time/DST stepping. */
function latestOccurrence(schedule, previous, now) {
  const weekdays = schedule.weekdays
  if (!weekdays || weekdays.length === 0) return null

  // Optimization: Instead of stepping minute-by-minute over the time range (which
  // requires O(minutes) iterations and thousands of Date allocations after sleep/gaps),
  // search candidate dates backwards from `now` to `previous`. Re-constructing
  // `candidate` for each day avoids hour drift across daylight saving time transitions.
  const dayCursor = new Date(now.getFullYear(), now.getMonth(), now.getDate())

  while (true) {
    const candidate = new Date(
      dayCursor.getFullYear(),
      dayCursor.getMonth(),
      dayCursor.getDate(),
      schedule.hour,
      schedule.minute,
      0,
      0
    )

    if (candidate <= previous) {
      break
    }

    if (candidate <= now) {
      if (
        weekdays.includes(weekdayOf(candidate)) &&
        candidate.getHours() === schedule.hour &&
        candidate.getMinutes() === schedule.minute
      ) {
        return candidate
      }
    }

    dayCursor.setDate(dayCursor.getDate() - 1)
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
