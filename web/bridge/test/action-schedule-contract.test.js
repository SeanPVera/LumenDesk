import test from 'node:test'
import assert from 'node:assert/strict'
import * as actions from '../src/actions.js'
import * as schedules from '../src/schedules.js'

const { applyCommand, applyScene, runSchedule, snapshot } = actions
const { ACTIONS, commandsFor, due, minutesOfDay, weekdayOf } = schedules

// Record observable calls, not private helpers, so these tests also run against
// the implementation before the refactor. No real devices or sockets are used.
function harness(brand = 'lifx', failures = []) {
  const events = []
  const device = { id: `${brand}:one`, brand, power: true, brightness: 50,
    color: { r: 10, g: 20, b: 30 }, kelvin: 3_500 }
  const devices = new Map([[device.id, device]])
  const registry = {
    claimControl(id) { events.push(['claim', id]) },
    patch(id, patch) {
      events.push(['patch', id, structuredClone(patch)])
      Object.assign(devices.get(id) ?? {}, patch)
    },
    get(id) { return devices.get(id) },
  }
  function client(name) {
    return Object.fromEntries(['setPower', 'setColor', 'setBrightness', 'displayPanels'].map(method => [
      method,
      function (target, payload) {
        assert.strictEqual(this, context[name], 'client method receiver must be preserved')
        events.push([name, method, target.id, structuredClone(payload)])
        return !failures.includes(method)
      },
    ]))
  }
  const context = { device, registry, lifx: client('lifx'), govee: client('govee'), nanoleaf: client('nanoleaf') }
  return { ...context, events, devices, context }
}

function apply(h, command) {
  return applyCommand({ ...h.context, command })
}

function withTimeZone(zone, run) {
  const previous = process.env.TZ
  process.env.TZ = zone
  try { return run() } finally {
    if (previous === undefined) delete process.env.TZ
    else process.env.TZ = previous
  }
}

function entry(overrides = {}) {
  return { id: 'schedule', isEnabled: true, hour: 9, minute: 0,
    weekdays: [1, 2, 3, 4, 5, 6, 7], action: 'turnOn', ...overrides }
}

function roomWith(...entries) {
  return { id: 'room', lightIDs: [], schedules: entries }
}

function state(overrides = {}) {
  return { kind: 'state', isOn: true, brightness: 25,
    color: { r: 255, g: 0, b: 0 }, kelvin: 3_000, ...overrides }
}

test('public exports, argument counts and ordered action identifiers are unchanged', () => {
  assert.deepEqual(Object.keys(actions).sort(), ['applyCommand', 'applyScene', 'runSchedule', 'snapshot'])
  assert.deepEqual(Object.keys(schedules).sort(), ['ACTIONS', 'commandsFor', 'due', 'minutesOfDay', 'weekdayOf'])
  for (const fn of [applyCommand, applyScene, runSchedule, snapshot, commandsFor, due, minutesOfDay, weekdayOf]) {
    assert.equal(fn.length, 1)
  }
  assert.deepEqual(ACTIONS, ['turnOn', 'turnOff', 'dim10', 'dim25', 'dim50', 'dim75', 'applyScene'])
})

test('command factories preserve supported commands, order, and strict unknown-action handling', () => {
  assert.deepEqual(commandsFor('turnOn'), [{ kind: 'power', on: true }])
  assert.deepEqual(commandsFor('turnOff'), [{ kind: 'power', on: false }])
  for (const level of [10, 25, 50, 75]) {
    assert.deepEqual(commandsFor(`dim${level}`), [
      { kind: 'power', on: true }, { kind: 'brightness', value: level },
    ])
  }
  for (const unknown of ['applyScene', 'dim0', 'dim100', 'constructor', 'toString', '__proto__',
    '', null, undefined, 25, new String('dim25'), Symbol('dim25')]) {
    assert.deepEqual(commandsFor(unknown), [])
  }
})

test('command factories return fresh arrays and command objects on every call', () => {
  for (const action of ACTIONS) {
    const first = commandsFor(action)
    const original = structuredClone(first)
    if (first[0]) first[0].kind = 'mutated'
    first.push({ kind: 'unexpected' })
    assert.deepEqual(commandsFor(action), original)
  }
})

test('calendar helpers retain native weekday numbering and local minute calculation', () => withTimeZone('UTC', () => {
  assert.equal(weekdayOf(new Date(2026, 6, 12, 14, 35)), 1)
  assert.equal(weekdayOf(new Date(2026, 6, 18, 14, 35)), 7)
  assert.equal(minutesOfDay(new Date(2026, 6, 13, 14, 35)), 875)
}))

test('schedule window is open at previous and closed at now without mutating input dates', () => withTimeZone('UTC', () => {
  const schedule = entry()
  const room = roomWith(schedule)
  const previous = new Date(2026, 6, 13, 8, 59, 59, 999)
  const now = new Date(2026, 6, 13, 9, 0)
  const before = [previous.getTime(), now.getTime()]
  const result = due({ rooms: [room], previous, now })
  assert.equal(result.length, 1)
  assert.strictEqual(result[0].room, room)
  assert.strictEqual(result[0].schedule, schedule)
  assert.deepEqual(result[0].at, now)
  assert.notStrictEqual(result[0].at, now)
  assert.deepEqual([previous.getTime(), now.getTime()], before)
  assert.deepEqual(due({ rooms: [room], previous: now, now: new Date(now.getTime() + 1_000) }), [])
}))

test('missing, empty, and reversed schedule windows return no decisions', () => {
  const now = new Date(2026, 6, 13, 9, 0)
  for (const previous of [null, undefined, now, new Date(now.getTime() + 1)]) {
    assert.deepEqual(due({ rooms: [roomWith(entry())], previous, now }), [])
  }
})

test('disabled entries, absent schedules, and empty or missing weekdays remain inactive in the bridge', () => withTimeZone('UTC', () => {
  const entries = [entry({ isEnabled: false }), entry({ weekdays: [] }), entry({ weekdays: undefined }),
    entry({ weekdays: [3] }), entry({ hour: 24 })]
  const result = due({ rooms: [{ id: 'empty' }, roomWith(...entries)],
    previous: new Date(2026, 6, 13, 8, 59), now: new Date(2026, 6, 13, 9, 1) })
  assert.deepEqual(result, [])
}))

test('schedule results preserve room/entry order, not chronological order', () => withTimeZone('UTC', () => {
  const later = entry({ id: 'later', minute: 5 })
  const earlier = entry({ id: 'earlier' })
  const rooms = [roomWith(later, earlier), { ...roomWith(entry({ id: 'other' })), id: 'other-room' }]
  const result = due({ rooms, previous: new Date(2026, 6, 13, 8, 59), now: new Date(2026, 6, 13, 9, 10) })
  assert.deepEqual(result.map(x => [x.room.id, x.schedule.id]), [
    ['room', 'later'], ['room', 'earlier'], ['other-room', 'other'],
  ])
}))

test('a multi-day window still fires each bridge schedule only once', () => withTimeZone('UTC', () => {
  const result = due({ rooms: [roomWith(entry())], previous: new Date(2026, 6, 13, 8, 59),
    now: new Date(2026, 6, 16, 10, 0) })
  assert.equal(result.length, 1)
  assert.deepEqual(result[0].at, new Date(2026, 6, 13, 9, 0))
}))

test('spring-forward skips nonexistent local times and keeps the next real minute', () => withTimeZone('America/New_York', () => {
  const skipped = entry({ id: 'skipped', hour: 2, minute: 30 })
  const valid = entry({ id: 'valid', hour: 3 })
  const result = due({ rooms: [roomWith(skipped, valid)],
    previous: new Date('2026-03-08T01:59:00-05:00'), now: new Date('2026-03-08T03:05:00-04:00') })
  assert.deepEqual(result.map(x => x.schedule.id), ['valid'])
  assert.equal(result[0].at.toISOString(), '2026-03-08T07:00:00.000Z')
}))

test('fall-back preserves existing local setMinutes behavior rather than adding elapsed minutes', () => withTimeZone('America/New_York', () => {
  const result = due({ rooms: [roomWith(entry({ hour: 1, minute: 30 }))],
    previous: new Date('2026-11-01T01:45:00-04:00'), now: new Date('2026-11-01T01:45:00-05:00') })
  assert.deepEqual(result, [])
}))

for (const brand of ['lifx', 'govee', 'nanoleaf']) {
  test(`${brand}: power is claimed, normalized, sent, then patched`, () => {
    const h = harness(brand)
    assert.equal(apply(h, { kind: 'power', on: 'yes' }), true)
    assert.deepEqual(h.events, [
      ['claim', h.device.id], [brand, 'setPower', h.device.id, true], ['patch', h.device.id, { power: true }],
    ])
  })

  test(`${brand}: failed power is not patched`, () => {
    const h = harness(brand, ['setPower'])
    assert.equal(apply(h, { kind: 'power', on: false }), false)
    assert.deepEqual(h.events, [['claim', h.device.id], [brand, 'setPower', h.device.id, false]])
  })

  test(`${brand}: brightness rounding, coercion, clamp and vendor channel stay unchanged`, () => {
    for (const [input, expected] of [[-10, 0], [101, 100], [25.5, 26], ['31.4', 31], ['bad', 0], [null, 0], [Infinity, 100]]) {
      const h = harness(brand)
      assert.equal(apply(h, { kind: 'brightness', value: input }), true)
      assert.deepEqual(h.events, [
        ['claim', h.device.id],
        [brand, brand === 'lifx' ? 'setColor' : 'setBrightness', h.device.id,
          brand === 'lifx' ? { brightnessPercent: expected } : expected],
        ['patch', h.device.id, { brightness: expected }],
      ])
    }
  })

  test(`${brand}: brightness failure leaves the registry unpatched`, () => {
    const h = harness(brand, [brand === 'lifx' ? 'setColor' : 'setBrightness'])
    assert.equal(apply(h, { kind: 'brightness', value: 25 }), false)
    assert.equal(h.events.length, 2)
    assert.equal(h.device.brightness, 50)
  })

  test(`${brand}: color preserves numeric kelvin and the existing-color fallback`, () => {
    const h = harness(brand)
    const color = h.device.color
    assert.equal(apply(h, { kind: 'color', kelvin: '4000' }), true)
    assert.deepEqual(h.events, [
      ['claim', h.device.id], [brand, 'setColor', h.device.id, { rgb: undefined, kelvin: 4000 }],
      ['patch', h.device.id, { color, kelvin: 4000 }],
    ])
  })

  test(`${brand}: color failure returns false without optimistic state changes`, () => {
    const h = harness(brand, ['setColor'])
    assert.equal(apply(h, { kind: 'color', rgb: { r: 1, g: 2, b: 3 } }), false)
    assert.equal(h.events.length, 2)
    assert.equal(h.device.kelvin, 3500)
  })

  test(`${brand}: off snapshots stop after power and preserve their uncoerced isOn value`, () => {
    const h = harness(brand)
    assert.equal(apply(h, state({ isOn: 0 })), true)
    assert.deepEqual(h.events, [
      ['claim', h.device.id], [brand, 'setPower', h.device.id, 0], ['patch', h.device.id, { power: 0 }],
    ])
  })

  test(`${brand}: state restore stops immediately on power failure`, () => {
    const h = harness(brand, ['setPower'])
    assert.equal(apply(h, state()), false)
    assert.deepEqual(h.events, [['claim', h.device.id], [brand, 'setPower', h.device.id, true]])
  })

  test(`${brand}: state restore keeps best-effort channel failures and final patch semantics`, () => {
    const h = harness(brand, ['setColor', 'setBrightness'])
    const command = state()
    assert.equal(apply(h, command), true)
    assert.deepEqual(h.events.at(-1), ['patch', h.device.id, {
      brightness: 25, color: command.color, kelvin: 3000,
    }])
    assert.equal(h.events.filter(x => x[1] === 'setColor').length, 1)
  })
}

test('LIFX captured HSBK is restored in one packet without mutating the snapshot', () => {
  const h = harness()
  const hsbk = { hue: 10, saturation: 20, brightness: 999, kelvin: 3500 }
  assert.equal(apply(h, state({ hsbk })), true)
  assert.deepEqual(h.events[3], ['lifx', 'setColor', h.device.id, {
    hsbk: { hue: 10, saturation: 20, brightness: 16384, kelvin: 3500 },
  }])
  assert.equal(h.events.filter(x => x[1] === 'setColor').length, 1)
  assert.equal(hsbk.brightness, 999)
})

test('LIFX legacy scenes prefer RGB over stored kelvin', () => {
  const h = harness()
  const command = state()
  apply(h, command)
  assert.deepEqual(h.events[3], ['lifx', 'setColor', h.device.id, {
    rgb: command.color, brightnessPercent: 25, kelvin: 0,
  }])
})

test('LIFX restore keeps the state values captured before a power callback', () => {
  const h = harness()
  const command = state()
  const originalColor = command.color
  h.context.lifx.setPower = () => { command.brightness = 90; command.color = null; return true }
  apply(h, command)
  assert.deepEqual(h.events[2], ['lifx', 'setColor', h.device.id, {
    rgb: originalColor, brightnessPercent: 25, kelvin: 0,
  }])
})

test('Nanoleaf restores a captured design before applying master brightness once', () => {
  const h = harness('nanoleaf')
  const design = { panels: [{ id: 1, r: 255, g: 0, b: 0 }] }
  apply(h, state({ design }))
  assert.deepEqual(h.events.slice(3, 5), [
    ['nanoleaf', 'displayPanels', h.device.id, design], ['nanoleaf', 'setBrightness', h.device.id, 25],
  ])
  assert.equal(h.events.filter(x => x[1] === 'setColor').length, 0)
})

for (const brand of ['govee', 'nanoleaf']) {
  test(`${brand}: separate channels preserve white precedence and RGB fallback`, () => {
    for (const kelvin of [3000, 0]) {
      const h = harness(brand)
      const command = state({ kelvin })
      apply(h, command)
      assert.deepEqual(h.events.slice(3, 5), [
        [brand, 'setColor', h.device.id, kelvin ? { kelvin } : { rgb: command.color }],
        [brand, 'setBrightness', h.device.id, 25],
      ])
    }
  })
}

test('Govee ignores a panel design rather than invoking Nanoleaf methods', () => {
  const h = harness('govee')
  apply(h, state({ design: { panels: [] } }))
  assert.equal(h.events.some(x => x[1] === 'displayPanels'), false)
  assert.deepEqual(h.events[3], ['govee', 'setColor', h.device.id, { kelvin: 3000 }])
})

test('unknown commands and unavailable clients still claim control before returning false', () => {
  for (const brand of ['unknown', 'nanoleaf', 'lifx']) {
    const h = harness(brand)
    if (brand === 'nanoleaf') h.context.nanoleaf = null
    assert.equal(apply(h, { kind: brand === 'lifx' ? 'unknown' : 'power', on: true }), false)
    assert.deepEqual(h.events, [['claim', h.device.id]])
  }
})

test('claimControl remains optional and client exceptions still propagate', () => {
  const h = harness()
  delete h.registry.claimControl
  assert.equal(apply(h, { kind: 'power', on: true }), true)
  const failure = new Error('transport failed')
  h.context.lifx.setPower = () => { throw failure }
  assert.throws(() => apply(h, { kind: 'power', on: false }), error => error === failure)
})

test('snapshot shape and retained vendor object references stay unchanged', () => {
  const h = harness('nanoleaf')
  const design = { panels: [] }
  const hsbk = { hue: 1 }
  h.device.shapes = { output: 'design', design }
  h.device.hsbk = hsbk
  const captured = snapshot([h.device])[h.device.id]
  assert.deepEqual(Object.keys(captured), ['isOn', 'brightness', 'color', 'kelvin', 'hsbk', 'design'])
  assert.strictEqual(captured.design, design)
  assert.strictEqual(captured.hsbk, hsbk)
  h.device.shapes.output = 'stream'
  assert.equal(snapshot([h.device])[h.device.id].design, null)
})

test('scene results retain resolved-device counting even when command dispatch fails', () => {
  const h = harness('lifx', ['setPower'])
  const scene = { snapshots: { [h.device.id]: state(), missing: state(), outside: state() } }
  const result = applyScene({ ...h.context, scene, onlyDeviceIDs: [h.device.id, 'missing'] })
  assert.deepEqual(result, { applied: [h.device.id], skipped: ['missing'] })
  assert.equal(h.events.filter(x => x[0] === 'claim').length, 1)
  assert.deepEqual(applyScene({ ...h.context, scene, onlyDeviceIDs: [] }), { applied: [], skipped: [] })
})

test('schedule dispatch preserves dependency injection, duplicate IDs, and per-device command ordering', () => {
  const h = harness('govee')
  const room = { lightIDs: [h.device.id, 'missing', h.device.id] }
  const calls = []
  const result = runSchedule({ ...h.context, room, schedule: { action: 'custom' },
    store: {}, commandsFor(action) { calls.push(action); return commandsFor('dim25') } })
  assert.deepEqual(calls, ['custom'])
  assert.deepEqual(result, { ran: true, devices: 2 })
  assert.deepEqual(h.events.filter(x => x[0] === 'govee').map(x => x[1]), [
    'setPower', 'setBrightness', 'setPower', 'setBrightness',
  ])
})

test('schedule error reasons and room-scoped scene application remain unchanged', () => {
  const h = harness()
  const room = { lightIDs: [h.device.id] }
  const scene = { id: 'scene', snapshots: { [h.device.id]: state(), outside: state() } }
  const context = { ...h.context, room, store: { listScenes: () => [scene] }, commandsFor }
  assert.deepEqual(runSchedule({ ...context, schedule: { action: 'applyScene', sceneID: 'missing' } }),
    { ran: false, reason: 'scene missing' })
  assert.deepEqual(runSchedule({ ...context, schedule: { action: 'unknown' } }),
    { ran: false, reason: 'unknown action' })
  assert.deepEqual(runSchedule({ ...context, schedule: { action: 'applyScene', sceneID: 'scene' } }),
    { ran: true, devices: 1 })
  assert.equal(h.events.filter(x => x[0] === 'claim').length, 1)
})
