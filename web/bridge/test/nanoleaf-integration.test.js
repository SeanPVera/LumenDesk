// End to end: the bridge pairs with a fake Shapes controller over real HTTP on
// loopback, reads its layout, and turns browser requests into the documented
// Shapes writes. What reached the "controller" is read back with a decoder
// that shares no code with the encoder under test.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { Registry } from '../src/registry.js'
import { NanoleafClient, credentialFileMode } from '../src/nanoleaf-client.js'
import { createServer } from '../src/server.js'
import { Store } from '../src/store.js'
import { FakeShapesController } from './fake-devices.js'

const ORIGIN = 'https://seanpvera.github.io'
const WALL = `nanoleaf:${FakeShapesController.serial}`
const PANELS = [9, 77, 1204, 5120, 31000, 64001]
let controller, controllerPort, registry, nanoleaf, server, base, directory

const inert = { setPower: () => false, setBrightness: () => false, setColor: () => false,
  discover: async () => null, refresh: () => {} }

const waitFor = async (predicate, { timeout = 4000, interval = 20 } = {}) => {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise(r => setTimeout(r, interval))
  }
  throw new Error('condition not met before timeout')
}

const api = (route, body) => fetch(`${base}${route}`, body === undefined ? {} : {
  method: 'POST', headers: { 'Content-Type': 'application/json', Origin: ORIGIN }, body: JSON.stringify(body),
}).then(async r => ({ status: r.status, text: await r.text() })).then(r => ({ ...r, body: r.text ? JSON.parse(r.text) : null }))

/** `[panel: [R, G, B, W, T]]` from one-frame static animData, independently. */
function decodeStatic(text) {
  const numbers = String(text ?? '').split(' ').map(Number)
  const result = {}
  let index = 1
  for (let n = 0; n < numbers[0]; n += 1) {
    assert.equal(numbers[index + 1], 1, 'one frame per panel')
    result[numbers[index]] = numbers.slice(index + 2, index + 7)
    index += 7
  }
  assert.equal(index, numbers.length, 'no trailing values')
  return result
}

before(async () => {
  controller = new FakeShapesController()
  controllerPort = await controller.listen()
  directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lumendesk-nanoleaf-'))
  registry = new Registry()
  nanoleaf = new NanoleafClient({ registry, credentialsFile: path.join(directory, 'pairings.json') })
  await nanoleaf.start()
  const store = new Store({ file: path.join(directory, 'state.json') })
  store.load()
  server = createServer({ registry, lifx: inert, govee: inert, nanoleaf, allowedOrigins: [ORIGIN], version: 'test', store })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${server.address().port}`
})

after(() => {
  server.close()
  controller.close()
  fs.rmSync(directory, { recursive: true, force: true })
})

test('pairing needs the controller’s window, and the credential never reaches the page', async () => {
  controller.pairingOpen = false
  const refused = await api('/nanoleaf/pair', { host: '127.0.0.1', port: controllerPort })
  assert.equal(refused.status, 403)
  assert.match(refused.body.error, /power button/)
  assert.equal((await api('/nanoleaf/pair', { host: 'http://127.0.0.1/x', port: controllerPort })).status, 400)

  controller.pairingOpen = true
  const paired = await api('/nanoleaf/pair', { host: '127.0.0.1', port: controllerPort })
  assert.equal(paired.status, 200)
  assert.equal(paired.body.device.id, WALL)
  assert.deepEqual(paired.body.device.shapes.layout.panels.filter(p => p.shapeCode !== 12).map(p => p.panelID).sort((a, b) => a - b), PANELS)
  assert.equal(paired.body.device.shapes.orientation, 240)
  assert.equal(paired.body.device.shapes.output, 'effect')

  const state = await api('/state')
  assert.ok(!state.text.includes(FakeShapesController.token), 'the token is not in anything the page can read')
  assert.ok(!paired.text.includes(FakeShapesController.token))
  assert.equal(credentialFileMode(path.join(directory, 'pairings.json')), 0o600, 'the credential file is private')
})

test('orientation is written as documented and counts only once read back', async () => {
  const response = await api(`/devices/${WALL}/orientation`, { degrees: -265 })
  assert.equal(response.status, 202)
  assert.equal(response.body.device.shapes.orientationPending, 95)
  await waitFor(() => registry.get(WALL).shapes.orientation === 95)
  const write = controller.requests.findLast(r => r.path.endsWith('/panelLayout'))
  assert.deepEqual(write.body, { globalOrientation: { value: 95 } })
  assert.equal(registry.get(WALL).shapes.orientationPending, null)
  assert.equal((await api(`/devices/${WALL}/orientation`, { degrees: 'up' })).status, 400)
})

test('panels are painted individually, uncovered panels dark, the controller never addressed', async () => {
  const response = await api(`/devices/${WALL}/panels`, { colors: { 9: { r: 255, g: 0, b: 0 }, 77: { r: 0, g: 0, b: 255 } } })
  assert.equal(response.status, 202)
  await waitFor(() => registry.get(WALL).shapes.output === 'design')
  const sent = decodeStatic(controller.animData)
  assert.deepEqual(Object.keys(sent).map(Number).sort((a, b) => a - b), PANELS)
  assert.deepEqual(sent[9].slice(0, 3), [255, 0, 0])
  assert.deepEqual(sent[77].slice(0, 3), [0, 0, 255])
  assert.deepEqual(sent[5120].slice(0, 3), [0, 0, 0])
  assert.equal(registry.get(WALL).shapes.design[9].r, 255)
  assert.equal((await api(`/devices/${WALL}/panels`, { colors: { 9: { r: 300, g: 0, b: 0 } } })).status, 400)
  assert.equal((await api(`/devices/${WALL}/panels`, { colors: { wall: { r: 1, g: 0, b: 0 } } })).status, 400)
})

test('a scene keeps the design and puts it back after another scene was chosen', async () => {
  const captured = await api('/scenes', { name: 'Red corner', deviceIDs: [WALL] })
  assert.equal(captured.status, 200)
  assert.equal(captured.body.scene.snapshots[WALL].design[9].r, 255)

  assert.equal((await api(`/devices/${WALL}/effect`, { name: 'Evening' })).status, 202)
  await waitFor(() => registry.get(WALL).shapes.output === 'effect' && controller.select === 'Evening')
  assert.equal(registry.get(WALL).shapes.design, null, 'a chosen scene releases the design')
  assert.equal((await api(`/devices/${WALL}/effect`, { name: 'Made up' })).status, 404)

  controller.animData = null
  const applied = await api(`/scenes/${captured.body.scene.id}/apply`, {})
  assert.equal(applied.status, 200)
  await waitFor(() => controller.animData && registry.get(WALL).shapes.output === 'design')
  assert.deepEqual(decodeStatic(controller.animData)[9].slice(0, 3), [255, 0, 0])
})

test('identify is a temporary display on one light panel only', async () => {
  assert.equal((await api(`/devices/${WALL}/identify`, { panelID: 0 })).status, 404, 'the controller is not a panel')
  assert.equal((await api(`/devices/${WALL}/identify`, { panelID: 1204 })).status, 202)
  const write = await waitFor(() => controller.requests.findLast(r => r.body?.write?.command === 'displayTemp'))
  assert.equal(write.body.write.duration, 4)
  assert.equal(controller.select, '*Static*', 'the wall’s own selection is not replaced')
})

test('power, brightness and colour use the shared controls', async () => {
  assert.equal((await api(`/devices/${WALL}/brightness`, { value: 42 })).status, 200)
  assert.equal((await api(`/devices/${WALL}/color`, { rgb: { r: 0, g: 255, b: 0 } })).status, 200)
  await waitFor(() => controller.state.colorMode === 'hs' && controller.state.brightness === 42)
  assert.equal(controller.state.hue, 120)
  await waitFor(() => registry.get(WALL).shapes.output === 'solid')
  assert.equal(registry.get(WALL).shapes.design, null)
})

test('browser music follows as one paced colour, and a restore brings the design back', async () => {
  const painted = await api(`/devices/${WALL}/panels`, { colors: { 9: { r: 255, g: 0, b: 0 }, 1204: { r: 0, g: 255, b: 0 } } })
  assert.equal(painted.status, 202)
  await waitFor(() => registry.get(WALL).shapes.output === 'design' && registry.get(WALL).shapes.design?.[1204]?.g === 255)
  const controlRevision = registry.get(WALL).controlRevision
  const frame = (rgb, extra = {}) => ({ fixtureID: WALL, rgb, brightness: 0.9, owner: 'show-1', controlRevision, ...extra })
  const firstRequest = controller.requests.length

  // Five frames as fast as the page can post them: the lane sends the first,
  // then only the newest, never faster than one every 200 ms.
  for (const hue of [0, 60, 120, 180, 240]) {
    const rgb = { 0: { r: 255, g: 0, b: 0 }, 60: { r: 255, g: 255, b: 0 }, 120: { r: 0, g: 255, b: 0 },
      180: { r: 0, g: 255, b: 255 }, 240: { r: 0, g: 0, b: 255 } }[hue]
    assert.equal((await api('/music/frame', { states: [frame(rgb)] })).status, 200)
  }
  const colourWrites = () => controller.requests.slice(firstRequest).filter(r => r.path.endsWith('/state') && 'hue' in (r.body ?? {}))
  await waitFor(() => colourWrites().at(-1)?.body.hue.value === 240)
  const writes = colourWrites()
  assert.ok(writes.length < 5, `newer frames replaced queued ones (${writes.length} writes)`)
  for (let i = 1; i < writes.length; i += 1) {
    assert.ok(writes[i].at - writes[i - 1].at >= 180, `writes ${Math.round(writes[i].at - writes[i - 1].at)} ms apart`)
  }
  assert.equal(controller.requests.slice(firstRequest).filter(r => r.method === 'GET').length, 0, 'music frames are not read back')

  controller.animData = null
  const restored = await api('/music/frame', { states: [frame({ r: 255, g: 255, b: 255 }, { restoring: true, brightness: 0.8 })] })
  assert.equal(restored.status, 200)
  await waitFor(() => controller.animData && registry.get(WALL).shapes.output === 'design')
  const sent = decodeStatic(controller.animData)
  assert.deepEqual(sent[9].slice(0, 3), [255, 0, 0])
  assert.deepEqual(sent[1204].slice(0, 3), [0, 255, 0])
  assert.equal(controller.state.brightness, 80)
  assert.equal(registry.get(WALL).musicOwner, null)
})

test('forgetting a wall removes the credential and the device', async () => {
  const response = await api(`/devices/${WALL}/forget`, {})
  assert.equal(response.status, 200)
  assert.equal(registry.get(WALL), null)
  const saved = JSON.parse(fs.readFileSync(path.join(directory, 'pairings.json'), 'utf8'))
  assert.deepEqual(saved, [])
})
