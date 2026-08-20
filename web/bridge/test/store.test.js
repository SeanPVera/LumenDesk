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
