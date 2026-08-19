// End-to-end: the bridge discovers fake lights over real UDP, serves them on
// its HTTP API, and turns HTTP commands back into correct protocol datagrams.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { Registry } from '../src/registry.js'
import { LifxClient } from '../src/lifx-client.js'
import { GoveeClient } from '../src/govee-client.js'
import { createServer } from '../src/server.js'
import { FakeLifxBulb, FakeGoveeDevice } from './fake-devices.js'

const ORIGIN = 'https://seanpvera.github.io'
let bulb, strip, registry, lifx, govee, server, base

const waitFor = async (predicate, { timeout = 4000, interval = 25 } = {}) => {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise(r => setTimeout(r, interval))
  }
  throw new Error('condition not met before timeout')
}

const api = (path, init) => fetch(`${base}${path}`, init).then(async r => ({
  status: r.status,
  headers: r.headers,
  body: await r.json().catch(() => null),
}))

before(async () => {
  bulb = new FakeLifxBulb({ label: 'Desk Lamp' })
  const bulbPort = await bulb.listen()

  registry = new Registry()
  // Point discovery at the fake bulb on loopback instead of the LAN broadcast.
  lifx = new LifxClient({ registry, discoveryAddress: '127.0.0.1', port: bulbPort })

  strip = new FakeGoveeDevice({ name: 'Fake Strip' })
  govee = new GoveeClient({
    registry,
    discoveryAddress: '127.0.0.1',
    responsePort: 0,
    joinMulticast: false,
  })
  await lifx.start()
  await govee.start()

  const ports = await strip.listen(govee.socket.address().port)
  govee.discoveryPort = ports.discoveryPort
  govee.controlPort = ports.controlPort

  server = createServer({
    registry,
    lifx,
    govee,
    allowedOrigins: [ORIGIN],
    version: 'test',
  })
  await new Promise(r => server.listen(0, '127.0.0.1', r))
  base = `http://127.0.0.1:${server.address().port}`
})

after(() => {
  bulb.close()
  strip.close()
  lifx.stop()
  govee.stop()
  server.close()
})

test('health endpoint identifies the bridge', async () => {
  const res = await api('/health')
  assert.equal(res.status, 200)
  assert.equal(res.body.service, 'lumendesk-bridge')
})

test('discovery finds both a LIFX and a Govee device over UDP', async () => {
  await api('/discover', { method: 'POST' })

  const devices = await waitFor(() => {
    const list = registry.list()
    return list.length >= 2 ? list : null
  })

  const lifxDevice = devices.find(d => d.brand === 'lifx')
  const goveeDevice = devices.find(d => d.brand === 'govee')

  assert.ok(lifxDevice, 'expected a LIFX device')
  assert.equal(lifxDevice.name, 'Desk Lamp') // label parsed off the wire
  assert.equal(lifxDevice.id, 'lifx:d073d5000a01')
  assert.equal(lifxDevice.reachable, true)

  assert.ok(goveeDevice, 'expected a Govee device')
  assert.equal(goveeDevice.name, 'Fake Strip')
  assert.equal(goveeDevice.ip, '127.0.0.1')
})

test('LIFX power command reaches the bulb and reports back', async () => {
  const res = await api('/devices/lifx%3Ad073d5000a01/power', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ on: true }),
  })
  assert.equal(res.status, 200)
  assert.equal(res.body.device.power, true) // optimistic echo

  await waitFor(() => bulb.power === 65535)
  assert.equal(bulb.power, 65535, 'bulb received SetLightPower with 65535')

  await api('/devices/lifx%3Ad073d5000a01/power', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ on: false }),
  })
  await waitFor(() => bulb.power === 0)
})

test('LIFX colour and brightness map into HSBK', async () => {
  await api('/devices/lifx%3Ad073d5000a01/color', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rgb: { r: 255, g: 0, b: 0 } }),
  })
  await waitFor(() => bulb.color.saturation > 60000)
  assert.equal(bulb.color.hue, 0, 'pure red is hue 0')
  assert.equal(bulb.color.saturation, 65535)

  await api('/devices/lifx%3Ad073d5000a01/brightness', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ value: 50 }),
  })
  await waitFor(() => Math.abs(bulb.color.brightness - 32768) < 100)
  // Setting brightness must not discard the hue set a moment ago.
  assert.equal(bulb.color.saturation, 65535, 'hue/saturation preserved across a brightness change')
})

test('Govee commands arrive as LAN JSON and update state', async () => {
  const id = encodeURIComponent(`govee:${strip.device}`)

  await api(`/devices/${id}/power`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ on: true }),
  })
  await waitFor(() => strip.onOff === 1)

  await api(`/devices/${id}/brightness`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ value: 42 }),
  })
  await waitFor(() => strip.brightness === 42)

  await api(`/devices/${id}/color`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rgb: { r: 10, g: 20, b: 30 } }),
  })
  await waitFor(() => strip.color.r === 10 && strip.color.b === 30)

  // The device's own devStatus reply must flow back into the registry.
  await waitFor(() => registry.get(`govee:${strip.device}`).brightness === 42)
})

test('Govee paces commands at least 100ms apart per device', async () => {
  const id = encodeURIComponent(`govee:${strip.device}`)
  const sent = []
  const original = govee.socket.send.bind(govee.socket)
  govee.socket.send = (...args) => {
    sent.push(Date.now())
    return original(...args)
  }

  await Promise.all(
    [10, 20, 30, 40].map(value =>
      api(`/devices/${id}/brightness`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ value }),
      }),
    ),
  )
  await waitFor(() => strip.brightness === 40, { timeout: 3000 })
  govee.socket.send = original

  for (let i = 1; i < sent.length; i += 1) {
    assert.ok(
      sent[i] - sent[i - 1] >= 90,
      `datagrams ${i - 1}->${i} were ${sent[i] - sent[i - 1]}ms apart, expected >=100ms`,
    )
  }
})

// Kept for older Chrome versions that still run the PNA preflight. Current
// Chrome gates this behind the Local Network Access permission prompt instead,
// which no server header can satisfy.
test('CORS and legacy Private Network Access headers allow the Pages origin', async () => {
  const res = await fetch(`${base}/devices`, {
    method: 'OPTIONS',
    headers: {
      Origin: ORIGIN,
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Private-Network': 'true',
    },
  })
  assert.equal(res.status, 204)
  assert.equal(res.headers.get('access-control-allow-origin'), ORIGIN)
  assert.equal(res.headers.get('access-control-allow-private-network'), 'true')
})

test('an unlisted origin is not granted access', async () => {
  const res = await fetch(`${base}/devices`, {
    headers: { Origin: 'https://evil.example' },
  })
  assert.equal(res.headers.get('access-control-allow-origin'), null)
})

test('bad input is rejected rather than sent to a light', async () => {
  const unknown = await api('/devices/lifx%3Adeadbeefdead/power', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ on: true }),
  })
  assert.equal(unknown.status, 404)

  const badColor = await api('/devices/lifx%3Ad073d5000a01/color', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ rgb: { r: 999, g: 0, b: 0 } }),
  })
  assert.equal(badColor.status, 400)
})
