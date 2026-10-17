import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createMusicController, MUSIC_RECOVERY_LEASE_MS } from '../src/music.js'
import { Registry } from '../src/registry.js'
import { createServer } from '../src/server.js'

function harness(brand = 'lifx', patch = {}) {
  const registry = new Registry()
  const id = `${brand}:lease`
  registry.upsert(id, { brightness: 67, color: { r: 80, g: 120, b: 240 }, kelvin: 3000,
    hsbk: brand === 'lifx' ? { hue: 1234, saturation: 456, brightness: 43210, kelvin: 3000 } : null, ...patch })
  const calls = []
  let accept = true, clock = 0
  const client = Object.fromEntries(['setColor', 'setBrightness', 'displayPanels', 'selectEffect'].map(method =>
    [method, (device, command) => { calls.push({ method, id: device.id, command }); if (accept instanceof Error) throw accept; return accept }]))
  const music = createMusicController({ registry, lifx: client, govee: client, nanoleaf: client, now: () => clock })
  const frame = { fixtureID: id, rgb: { r: 255, g: 0, b: 0 }, brightness: 0.2,
    owner: 'show', controlRevision: 0, restoreOnDisconnect: true }
  return { registry, id, calls, music, client, frame,
    at(time) { clock = time }, accept(value) { accept = value } }
}

test('an abandoned owned show restores exact starting HSBK and fences late output', () => {
  const h = harness(), before = structuredClone(h.registry.get(h.id))
  assert.equal(h.music.frame([h.frame]).applied, 1)
  h.at(MUSIC_RECOVERY_LEASE_MS - 1)
  h.music.expire()
  assert.equal(h.calls.length, 1)
  h.at(MUSIC_RECOVERY_LEASE_MS)
  h.music.expire()
  assert.deepEqual(h.calls.at(-1).command.hsbk, before.hsbk)
  assert.equal(h.registry.get(h.id).musicOwner, null)
  assert.equal(h.registry.get(h.id).controlRevision, 1)
  assert.deepEqual(h.registry.get(h.id).color, before.color)
  const writes = h.calls.length
  assert.equal(h.music.frame([h.frame, { ...h.frame, heartbeat: true }]).applied, 0)
  assert.equal(h.calls.length, writes, 'a delayed frame cannot reclaim an expired lease')
})

test('frames and heartbeat renew the lease without repainting, and follow the latest restore choice', () => {
  const h = harness()
  h.music.frame([h.frame])
  h.at(4000)
  h.music.frame([{ ...h.frame, heartbeat: true }])
  assert.equal(h.calls.length, 1)
  h.at(6000)
  h.music.expire()
  assert.equal(h.registry.get(h.id).musicOwner, 'show')
  h.music.frame([{ ...h.frame, heartbeat: true, restoreOnDisconnect: false }])
  h.at(11000)
  h.music.expire()
  assert.equal(h.calls.length, 1, 'the latest preference releases the last output instead of restoring')
  assert.equal(h.registry.get(h.id).musicOwner, null)
  assert.equal(h.registry.get(h.id).brightness, 20)
})

test('a heartbeat cannot claim a light and a second live owner cannot replace the starting snapshot', () => {
  const h = harness()
  const early = h.music.frame([{ ...h.frame, heartbeat: true }])
  assert.equal(early.rejectedOwnership, undefined, 'an early heartbeat is not evidence that a not-yet-claimed show lost its lease')
  assert.equal(h.registry.get(h.id).musicOwner, undefined)
  h.music.frame([h.frame])
  h.at(3000)
  assert.equal(h.music.frame([{ ...h.frame, owner: 'other-show' }]).applied, 0)
  assert.equal(h.calls.length, 1)
})

test('a failed recovery retries its original snapshot and cannot be revived by a late frame', () => {
  const h = harness(), before = structuredClone(h.registry.get(h.id).hsbk)
  h.music.frame([h.frame])
  h.accept(false)
  h.at(6000)
  h.music.expire()
  assert.equal(h.registry.get(h.id).musicOwner, 'show')
  const attempts = h.calls.length
  h.music.frame([{ ...h.frame, heartbeat: true }])
  assert.equal(h.calls.length, attempts + 1, 'only recovery is retried; heartbeat does not renew an expired show')
  h.accept(true)
  h.at(7000)
  h.music.expire()
  assert.deepEqual(h.calls.at(-1).command.hsbk, before)
  assert.equal(h.registry.get(h.id).musicOwner, null)
})

test('newer manual, scene or scheduled ownership prevents abandoned Music restoration', () => {
  const h = harness()
  h.music.frame([h.frame])
  h.registry.claimControl(h.id)
  h.registry.patch(h.id, { brightness: 81, color: { r: 0, g: 255, b: 0 } })
  h.at(6000)
  h.music.expire()
  assert.equal(h.calls.length, 1)
  assert.equal(h.registry.get(h.id).brightness, 81)
  assert.equal(h.music.frame([{ ...h.frame, restoring: true }]).applied, 0)
})

test('an exception during automatic recovery retains the snapshot without terminating the bridge timer', () => {
  const h = harness()
  h.music.frame([h.frame])
  h.accept(new Error('temporary client error'))
  h.at(6000)
  assert.doesNotThrow(() => h.music.expire())
  assert.equal(h.registry.get(h.id).musicOwner, 'show')
  h.accept(true)
  h.music.expire()
  assert.equal(h.registry.get(h.id).musicOwner, null)
})

test('explicit restore and release also fence requests that arrive after a reload cleanup', () => {
  for (const cleanup of [{ restoring: true }, { release: true }]) {
    const h = harness()
    h.music.frame([h.frame])
    h.music.frame([{ ...h.frame, ...cleanup }])
    const writes = h.calls.length
    assert.equal(h.registry.get(h.id).controlRevision, 1)
    assert.equal(h.music.frame([h.frame]).applied, 0)
    assert.equal(h.calls.length, writes)
  }
})

test('Govee recovery restores white mode and independent brightness, retrying a rejected brightness write', () => {
  const h = harness('govee', { kelvin: 3500 })
  h.music.frame([h.frame])
  h.accept(false)
  h.at(6000)
  h.music.expire()
  assert.equal(h.calls.at(-1).method, 'setBrightness')
  assert.equal(h.registry.get(h.id).musicOwner, 'show')
  h.accept(true)
  h.music.expire()
  assert.deepEqual(h.calls.at(-1), { method: 'setColor', id: h.id, command: { kelvin: 3500 } })
  assert.ok(h.calls.some(call => call.method === 'setBrightness' && call.command === 67))
  assert.equal(h.registry.get(h.id).musicOwner, null)
})

test('Nanoleaf recovery retains the exact panel design, controller effect or white mode', () => {
  for (const [output, value, method] of [
    ['design', { 1: { r: 10, g: 20, b: 30 }, 2: { r: 50, g: 60, b: 70 } }, 'displayPanels'],
    ['effect', 'Northern Lights', 'selectEffect'],
    ['white', 3400, 'setColor'],
  ]) {
    const h = harness('nanoleaf', { kelvin: output === 'white' ? value : null,
      shapes: { output, design: output === 'design' ? value : null, effect: output === 'effect' ? value : null } })
    h.music.frame([h.frame])
    h.at(6000)
    h.music.expire()
    assert.equal(h.calls.at(-1).method, method)
    assert.deepEqual(h.calls.at(-1).command, output === 'white' ? { kelvin: value } : value)
    assert.ok(h.calls.some(call => call.method === 'setBrightness' && call.command === 67))
    assert.equal(h.registry.get(h.id).musicOwner, null)
  }
})

test('the HTTP bridge recovers after the browser stops sending without any cleanup request', async t => {
  const h = harness(), before = structuredClone(h.registry.get(h.id).hsbk)
  const server = createServer({ registry: h.registry, lifx: h.client, govee: h.client, allowedOrigins: [], version: 'test' })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve) }))
  const base = `http://127.0.0.1:${server.address().port}`
  assert.equal((await (await fetch(`${base}/state`)).json()).musicRecoveryLeaseMS, MUSIC_RECOVERY_LEASE_MS)
  const response = await fetch(`${base}/music/frame`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ states: [h.frame] }) })
  assert.equal(response.status, 200)
  const deadline = Date.now() + MUSIC_RECOVERY_LEASE_MS + 2000
  while (h.registry.get(h.id).musicOwner && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 30))
  assert.equal(h.registry.get(h.id).musicOwner, null)
  assert.deepEqual(h.calls.at(-1).command.hsbk, before)
})
