// Rooms, scenes and schedules live in the bridge so they survive reloads and
// run with no browser open. Schedule evaluation is pure and clock-injected,
// mirroring the native ScheduleEngine, so nothing here waits on real time.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Store } from '../src/store.js'
import { due, commandsFor, weekdayOf } from '../src/schedules.js'
import { applyScene, snapshot } from '../src/actions.js'
import { Registry } from '../src/registry.js'

const tmpStore = async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-store-'))
  return new Store({ file: path.join(dir, 'state.json') })
}

test('rooms round-trip through the file and reload', async () => {
  const store = await tmpStore()
  store.load()
  const room = store.addRoom('Studio')
  store.assignLight('lifx:aaa', room.id)
  await store.save()

  const reloaded = new Store({ file: store.file })
  reloaded.load()
  assert.equal(reloaded.listRooms().length, 1)
  assert.equal(reloaded.listRooms()[0].name, 'Studio')
  assert.deepEqual(reloaded.listRooms()[0].lightIDs, ['lifx:aaa'])
})

test('a light belongs to at most one room', async () => {
  const store = await tmpStore()
  store.load()
  const a = store.addRoom('A')
  const b = store.addRoom('B')
  store.assignLight('lifx:x', a.id)
  store.assignLight('lifx:x', b.id)
  assert.deepEqual(store.listRooms().find(r => r.id === a.id).lightIDs, [])
  assert.deepEqual(store.listRooms().find(r => r.id === b.id).lightIDs, ['lifx:x'])

  store.assignLight('lifx:x', null) // unassign
  assert.deepEqual(store.listRooms().find(r => r.id === b.id).lightIDs, [])
})

test('a missing or corrupt state file loads as empty rather than throwing', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-bad-'))
  const file = path.join(dir, 'state.json')

  const missing = new Store({ file })
  assert.deepEqual(missing.load().rooms, [])

  await fs.writeFile(file, '{ not json at all')
  const corrupt = new Store({ file })
  assert.deepEqual(corrupt.load().rooms, [])

  await fs.writeFile(file, '{"rooms": "nonsense", "scenes": 42}')
  const wrongTypes = new Store({ file })
  const state = wrongTypes.load()
  assert.deepEqual(state.rooms, [])
  assert.deepEqual(state.scenes, [])
})

test('schedules fire once inside the window and not outside it', () => {
  const rooms = [
    {
      id: 'r1',
      name: 'Studio',
      lightIDs: ['lifx:a'],
      schedules: [
        { id: 's1', isEnabled: true, hour: 7, minute: 30, action: 'turnOn', weekdays: [1, 2, 3, 4, 5, 6, 7] },
      ],
    },
  ]
  const at = (h, m) => new Date(2026, 0, 5, h, m, 0) // a Monday

  assert.equal(due({ rooms, previous: at(7, 29), now: at(7, 31) }).length, 1)
  assert.equal(due({ rooms, previous: at(7, 31), now: at(7, 45) }).length, 0)
  // The same minute must not fire twice across consecutive windows.
  assert.equal(due({ rooms, previous: at(7, 30), now: at(7, 31) }).length, 0)
})

test('a long gap still runs a missed schedule exactly once', () => {
  const rooms = [
    {
      id: 'r1',
      name: 'Studio',
      lightIDs: [],
      schedules: [
        { id: 's1', isEnabled: true, hour: 3, minute: 0, action: 'turnOff', weekdays: [1, 2, 3, 4, 5, 6, 7] },
      ],
    },
  ]
  // Machine asleep from 01:00 to 09:00 — the 03:00 entry is caught, once.
  const decisions = due({
    rooms,
    previous: new Date(2026, 0, 5, 1, 0),
    now: new Date(2026, 0, 5, 9, 0),
  })
  assert.equal(decisions.length, 1)
  assert.equal(decisions[0].schedule.id, 's1')
})

test('disabled entries and non-matching weekdays never fire', () => {
  const base = { id: 's', hour: 7, minute: 30, action: 'turnOn' }
  const monday = { previous: new Date(2026, 0, 5, 7, 29), now: new Date(2026, 0, 5, 7, 31) }
  assert.equal(weekdayOf(new Date(2026, 0, 5)), 2) // Monday = 2

  const disabled = [{ id: 'r', lightIDs: [], schedules: [{ ...base, isEnabled: false, weekdays: [2] }] }]
  assert.equal(due({ rooms: disabled, ...monday }).length, 0)

  const wrongDay = [{ id: 'r', lightIDs: [], schedules: [{ ...base, isEnabled: true, weekdays: [1] }] }]
  assert.equal(due({ rooms: wrongDay, ...monday }).length, 0)

  const rightDay = [{ id: 'r', lightIDs: [], schedules: [{ ...base, isEnabled: true, weekdays: [2] }] }]
  assert.equal(due({ rooms: rightDay, ...monday }).length, 1)
})

test('dim actions turn the light on as well as setting a level', () => {
  assert.deepEqual(commandsFor('turnOff'), [{ kind: 'power', on: false }])
  assert.deepEqual(commandsFor('dim25'), [
    { kind: 'power', on: true },
    { kind: 'brightness', value: 25 },
  ])
  assert.deepEqual(commandsFor('nonsense'), [])
})

test('a scene captures and restores device state, skipping ones that vanished', () => {
  const registry = new Registry()
  registry.upsert('lifx:a', { name: 'A', ip: '127.0.0.1', power: true, brightness: 80, color: { r: 1, g: 2, b: 3 } })
  registry.upsert('govee:b', { name: 'B', ip: '127.0.0.1', power: false, brightness: 10, color: null })

  const snaps = snapshot(registry.list())
  assert.equal(snaps['lifx:a'].isOn, true)
  assert.equal(snaps['lifx:a'].brightness, 80)
  assert.equal(snaps['govee:b'].isOn, false)

  const sent = []
  const fakeClient = {
    setPower: (d, on) => (sent.push([d.id, 'power', on]), true),
    setColor: (d, o) => (sent.push([d.id, 'color', o]), true),
    setBrightness: (d, v) => (sent.push([d.id, 'brightness', v]), true),
  }
  const scene = { snapshots: { ...snaps, 'lifx:gone': { isOn: true, brightness: 50 } } }
  const result = applyScene({ scene, registry, lifx: fakeClient, govee: fakeClient })

  assert.deepEqual(result.skipped, ['lifx:gone'])
  assert.ok(result.applied.includes('lifx:a'))
  assert.ok(sent.some(([id, kind, v]) => id === 'lifx:a' && kind === 'power' && v === true))
  // An off device is not given a colour or brightness it cannot show.
  assert.ok(!sent.some(([id, kind]) => id === 'govee:b' && kind === 'brightness'))
})

// --- regressions from the review of the full-shell change ---

test('restoring a LIFX scene sends colour and brightness in one packet', () => {
  // LIFX carries hue/sat/brightness/kelvin in a single SetColor. Sending
  // colour then brightness rebuilt the second packet from the device's stale
  // HSBK and silently undid the colour.
  const registry = new Registry()
  registry.upsert('lifx:a', {
    name: 'A',
    ip: '127.0.0.1',
    power: false,
    brightness: 10,
    color: { r: 0, g: 0, b: 0 },
    hsbk: { hue: 0, saturation: 0, brightness: 6553, kelvin: 3500 },
  })

  const calls = []
  const lifx = {
    setPower: () => true,
    setColor: (_d, opts) => (calls.push(opts), true),
  }
  const scene = {
    snapshots: { 'lifx:a': { isOn: true, brightness: 75, color: { r: 255, g: 0, b: 0 }, kelvin: null } },
  }
  applyScene({ scene, registry, lifx, govee: lifx })

  assert.equal(calls.length, 1, 'exactly one SetColor, not one per channel')
  assert.deepEqual(calls[0].rgb, { r: 255, g: 0, b: 0 })
  assert.equal(calls[0].brightnessPercent, 75, 'brightness travels with the colour')
})

test('a room-scoped scene apply leaves other rooms alone', () => {
  const registry = new Registry()
  registry.upsert('lifx:mine', { name: 'Mine', ip: '127.0.0.1' })
  registry.upsert('lifx:theirs', { name: 'Theirs', ip: '127.0.0.1' })

  const touched = []
  const client = {
    setPower: d => (touched.push(d.id), true),
    setColor: () => true,
    setBrightness: () => true,
  }
  const scene = {
    snapshots: {
      'lifx:mine': { isOn: true, brightness: 50 },
      'lifx:theirs': { isOn: true, brightness: 50 },
    },
  }
  const result = applyScene({
    scene,
    registry,
    lifx: client,
    govee: client,
    onlyDeviceIDs: ['lifx:mine'],
  })

  assert.deepEqual(touched, ['lifx:mine'])
  assert.deepEqual(result.applied, ['lifx:mine'])
})

test('rooms with malformed nested fields are repaired on load', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-nested-'))
  const file = path.join(dir, 'state.json')
  await fs.writeFile(
    file,
    JSON.stringify({
      rooms: [
        { id: 'ok', name: 'Fine', lightIDs: ['lifx:a'], schedules: [] },
        { id: 'bad', name: 'Broken', lightIDs: 'not-an-array', schedules: 'also-not' },
        { name: 'no id' },
        null,
      ],
      scenes: [{ id: 's', name: 'S', snapshots: {} }, { id: 'no-snapshots' }],
    }),
  )
  const store = new Store({ file })
  const state = store.load()

  assert.equal(state.rooms.length, 2, 'entries without an id are dropped')
  const broken = state.rooms.find(r => r.id === 'bad')
  assert.deepEqual(broken.lightIDs, [], 'a non-array lightIDs becomes an array')
  assert.deepEqual(broken.schedules, [], 'a non-array schedules becomes an array')
  assert.equal(state.scenes.length, 1, 'a scene without snapshots is dropped')

  // The repaired shape must be safe for the code paths that previously threw.
  assert.doesNotThrow(() => state.rooms.some(r => r.lightIDs.includes('lifx:a')))
  assert.doesNotThrow(() => due({ rooms: state.rooms, previous: new Date(0), now: new Date() }))
})

test('assigning to a missing room leaves existing membership untouched', async () => {
  const store = await tmpStore()
  store.load()
  const room = store.addRoom('Studio')
  store.assignLight('lifx:x', room.id)

  assert.equal(store.assignLight('lifx:x', 'no-such-room'), false)
  assert.deepEqual(
    store.listRooms().find(r => r.id === room.id).lightIDs,
    ['lifx:x'],
    'a failed assignment must not strip the light from the room it was in',
  )
})

test('flush reports a write that actually failed', async () => {
  // A regular file standing where a directory should be fails fast and
  // portably, unlike unwritable virtual filesystems.
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-ro-'))
  const blocker = path.join(dir, 'blocker')
  await fs.writeFile(blocker, 'not a directory')

  const store = new Store({ file: path.join(blocker, 'state.json') })
  store.load()
  store.addRoom('Studio')
  await assert.rejects(() => store.flush(), /could not save state/)

  // The failure is reported once, then cleared, so a later good write is clean.
  await store.flush()
})

test('a saturated LIFX colour survives capture and restore', () => {
  // The first fix was wrong: LIFX reports a kelvin even for a saturated
  // colour, so treating a non-zero kelvin as "white mode" zeroed the
  // saturation and lost the colour. The captured HSBK is replayed instead.
  const registry = new Registry()
  const captured = { hue: 3488, saturation: 38799, brightness: 49151, kelvin: 3500 }
  registry.upsert('lifx:a', {
    name: 'A',
    ip: '127.0.0.1',
    power: true,
    brightness: 75,
    color: { r: 201, g: 120, b: 82 },
    kelvin: 3500,
    hsbk: captured,
  })

  const snaps = snapshot(registry.list())
  assert.deepEqual(snaps['lifx:a'].hsbk, captured, 'the snapshot keeps the exact HSBK')

  // Device drifts to a dim green before the scene is applied.
  registry.upsert('lifx:a', {
    brightness: 20,
    hsbk: { hue: 20207, saturation: 21605, brightness: 13107, kelvin: 3500 },
  })

  const sent = []
  const lifx = { setPower: () => true, setColor: (_d, o) => (sent.push(o), true) }
  applyScene({ scene: { snapshots: snaps }, registry, lifx, govee: lifx })

  assert.equal(sent.length, 1)
  assert.equal(sent[0].hsbk.hue, captured.hue, 'hue restored')
  assert.equal(sent[0].hsbk.saturation, captured.saturation, 'saturation not zeroed')
  assert.ok(Math.abs(sent[0].hsbk.brightness - captured.brightness) < 700, 'brightness restored')
})
