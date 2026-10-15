// End-to-end: the bridge discovers fake lights over real UDP, serves them on
// its HTTP API, and turns HTTP commands back into correct protocol datagrams.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import http from 'node:http'
import net from 'node:net'
import dgram from 'node:dgram'
import { Registry } from '../src/registry.js'
import { LifxClient } from '../src/lifx-client.js'
import { GoveeClient } from '../src/govee-client.js'
import { createServer } from '../src/server.js'
import { FakeLifxBulb, FakeGoveeDevice } from './fake-devices.js'
import { percentToU16, rgbToHsv, u16ToPercent } from '../src/color.js'
import { Message as lifxMessages } from '../src/lifx.js'

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

const directRequest = (address, path, { method = 'GET', headers = {} } = {}) => new Promise((resolve, reject) => {
  const url = new URL(address)
  const req = http.request({ hostname: url.hostname.replace(/^\[|\]$/g, ''), port: url.port, path, method, headers }, res => {
    const chunks = []
    res.on('data', chunk => chunks.push(chunk))
    res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }))
  })
  req.on('error', reject)
  req.end()
})

before(async () => {
  bulb = new FakeLifxBulb({ label: 'Desk Lamp' })
  const bulbPort = await bulb.listen()

  registry = new Registry()
  // Point discovery at the fake bulb on loopback instead of the LAN broadcast.
  lifx = new LifxClient({ registry, discoveryAddress: '127.0.0.1', port: bulbPort, sweep: false, broadcastRounds: 1 })

  // 192.0.2.0/24 is TEST-NET-1: guaranteed unroutable. The device announces
  // it while actually answering from loopback, which is the shape of the bug
  // that made every command come back EHOSTUNREACH.
  strip = new FakeGoveeDevice({ name: 'Fake Strip', reportedIP: '192.0.2.99' })
  govee = new GoveeClient({
    registry,
    discoveryAddress: '127.0.0.1',
    responsePort: 0,
    joinMulticast: false,
    sweep: false,
    broadcastRounds: 1,
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

test('a colour sent before the bulb answers keeps the brightness just set', async () => {
  const id = 'lifx%3Ad073d5000a01'
  const green = rgbToHsv({ r: 0, g: 255, b: 0 })
  const greenHue = Math.round((green.h / 360) * 65535)
  const dim = percentToU16(20)

  // Hold the bulb's StateLight replies so the second command lands inside the
  // window a real LAN always has. Every channel the client does not change is
  // read back out of its own HSBK mirror, so a stale mirror made the colour
  // packet rebuild brightness from the pre-change value and undo it.
  const realSend = bulb.socket.send.bind(bulb.socket)
  const held = []
  bulb.socket.send = (...args) => held.push(args)
  try {
    await api(`/devices/${id}/brightness`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ value: 20 }),
    })
    await waitFor(() => bulb.color.brightness === dim)

    await api(`/devices/${id}/color`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ rgb: { r: 0, g: 255, b: 0 } }),
    })
    // Wait on the colour itself: the bulb was already saturated, so waiting on
    // saturation alone would return before this command had landed at all.
    await waitFor(() => bulb.color.hue === greenHue)

    assert.equal(
      bulb.color.brightness,
      dim,
      `colour command reverted brightness to ${u16ToPercent(bulb.color.brightness)}%`,
    )
  } finally {
    bulb.socket.send = realSend
    held.forEach(args => realSend(...args))
  }
})

test('music frame paints one solid colour per fixture and never invents razer', async () => {
  const devices = await waitFor(() => {
    const list = registry.list()
    return list.length >= 2 ? list : null
  })
  const lifxDevice = devices.find(d => d.brand === 'lifx')
  const goveeDevice = devices.find(d => d.brand === 'govee')
  const brightnessBefore = bulb.color.brightness

  const res = await api('/music/frame', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Origin: ORIGIN },
    body: JSON.stringify({
      states: [
        { fixtureID: lifxDevice.id, rgb: { r: 20, g: 40, b: 200 } },
        { fixtureID: goveeDevice.id, rgb: { r: 20, g: 40, b: 200 } },
        // A second state for a fixture already painted this frame. One colour
        // per fixture means this one is dropped, not sent after the first.
        { fixtureID: lifxDevice.id, rgb: { r: 255, g: 0, b: 0 } },
      ],
    }),
  })
  assert.equal(res.status, 200)
  assert.equal(res.body.ok, true)
  assert.equal(res.body.applied, 2)

  // Assert what the lights actually received over UDP. The registry's own
  // colour is an optimistic echo that the device's next authoritative reply
  // legitimately replaces, so it cannot stand in for the device's state.
  const hsv = rgbToHsv({ r: 20, g: 40, b: 200 })
  const expectedHue = Math.round((hsv.h / 360) * 65535)
  await waitFor(() => bulb.color.hue === expectedHue)
  assert.equal(bulb.color.hue, expectedHue, 'bulb holds the first colour, not the duplicate')
  assert.equal(bulb.color.saturation, Math.round(hsv.s * 65535))
  assert.equal(
    bulb.color.brightness,
    brightnessBefore,
    'a music frame carries colour only and must not move the light off its brightness',
  )
  await waitFor(() => strip.color.b === 200)
  assert.deepEqual(strip.color, { r: 20, g: 40, b: 200 })

  // "never invents razer": the RGBIC streaming extensions are not spoken on
  // this path, so an RGBIC strip follows as a single wash.
  assert.ok(!strip.received.includes('razer'), 'no razer packet was sent')
  assert.ok(!strip.received.includes('ptReal'), 'no ptReal packet was sent')
  assert.ok(!bulb.received.includes(lifxMessages.set64), 'no LIFX matrix packet was sent')
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

test('a disallowed origin cannot mutate, even though CORS would let it send', async () => {
  // CORS only hides the response; a simple POST still reaches the server and
  // still acts. State-changing requests must be refused outright.
  const before = await api('/devices')
  const res = await fetch(`${base}/devices/lifx%3Ad073d5000a01/power`, {
    method: 'POST',
    headers: { Origin: 'https://evil.example', 'Content-Type': 'text/plain' },
    body: JSON.stringify({ on: true }),
  })
  assert.equal(res.status, 403)
  assert.equal((await res.json()).error, 'origin not allowed')
  // And the light is untouched.
  assert.deepEqual((await api('/devices')).body.devices.length, before.body.devices.length)
})

test('the page the bridge serves may mutate on its own origin', async () => {
  const host = new URL(base).host
  const res = await fetch(`${base}/devices/lifx%3Ad073d5000a01/power`, {
    method: 'POST',
    headers: { Origin: `http://${host}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ on: false }),
  })
  assert.equal(res.status, 200)
})

test('a request with no Origin at all (curl, a script) still works', async () => {
  const res = await fetch(`${base}/devices/lifx%3Ad073d5000a01/power`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ on: false }),
  })
  assert.equal(res.status, 200)
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

test('a Govee device that announces a stale address is still commandable', async () => {
  // The scan reply claims 192.0.2.99 but arrives from loopback. Trusting the
  // claim pointed every command at a dead address: sendto answered
  // EHOSTUNREACH ("no route to host") while discovery kept listing the light
  // as present. The source address is the one that provably works.
  const device = await waitFor(() => registry.get(`govee:${strip.device}`))
  assert.equal(device.ip, '127.0.0.1', 'the address the reply came from wins')
  assert.notEqual(device.ip, '192.0.2.99', 'the self-reported address must not be trusted')

  // And it is actually reachable at that address.
  const id = encodeURIComponent(`govee:${strip.device}`)
  await api(`/devices/${id}/brightness`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ value: 61 }),
  })
  await waitFor(() => strip.brightness === 61)
})

test('explicit music brightness reaches LIFX and Govee, and restores both', async () => {
  const devices = registry.list(), l = devices.find(d=>d.brand==='lifx'), g = devices.find(d=>d.brand==='govee')
  const send = states => api('/music/frame',{method:'POST',headers:{'Content-Type':'application/json',Origin:ORIGIN},body:JSON.stringify({states})})
  const before = {l:bulb.color.brightness,g:strip.brightness}
  let result=await send([l,g].map(d=>({fixtureID:d.id,rgb:{r:255,g:0,b:0},brightness:.2,transitionDuration:.09})))
  assert.equal(result.body.stage,'accepted-for-local-dispatch')
  await waitFor(()=>Math.abs(bulb.color.brightness-percentToU16(20))<=1 && strip.color.r===51 && strip.brightness===100)
  assert.equal(bulb.color.saturation,65535)
  result=await send([{fixtureID:l.id,rgb:{r:255,g:0,b:0},brightness:before.l/65535,restoring:true},
    {fixtureID:g.id,rgb:{r:255,g:0,b:0},brightness:before.g/100,restoring:true}])
  assert.equal(result.body.applied,2)
  await waitFor(()=>Math.abs(bulb.color.brightness-before.l)<=1 && strip.brightness===before.g && strip.color.r===255)
})

test('newer manual control revokes music frames and stale restoration', async()=>{
  const device=registry.list().find(d=>d.brand==='lifx'), revision=device.controlRevision
  const send=state=>api('/music/frame',{method:'POST',headers:{'Content-Type':'application/json',Origin:ORIGIN},body:JSON.stringify({states:[state]})})
  const frame={fixtureID:device.id,rgb:{r:255,g:0,b:0},brightness:.2,owner:'regression-show',controlRevision:revision}
  assert.equal((await send(frame)).body.applied,1)
  await api(`/devices/${encodeURIComponent(device.id)}/brightness`,{method:'POST',headers:{'Content-Type':'application/json',Origin:ORIGIN},body:JSON.stringify({value:65})})
  assert.equal((await send(frame)).body.applied,0)
  assert.equal((await send({...frame,restoring:true})).body.applied,0)
  await waitFor(()=>Math.abs(bulb.color.brightness-percentToU16(65))<=1)
})

test('owned Music restores exact LIFX white and saturated HSBK instead of an RGB approximation', async () => {
  await api('/discover', { method: 'POST' })
  const device = await waitFor(() => registry.list().find(d => d.brand === 'lifx' && d.hsbk))
  const headers = { 'Content-Type': 'application/json', Origin: ORIGIN }
  const send = state => api('/music/frame', { method: 'POST', headers, body: JSON.stringify({ states: [state] }) })
  for (const [index, color] of [{ kelvin: 2700 }, { rgb: { r: 45, g: 210, b: 90 } }].entries()) {
    await api(`/devices/${encodeURIComponent(device.id)}/color`, { method: 'POST', headers, body: JSON.stringify(color) })
    const expected = structuredClone(registry.get(device.id).hsbk)
    await waitFor(() => JSON.stringify(bulb.color) === JSON.stringify(expected))
    const frame = { fixtureID: device.id, rgb: { r: 0, g: 0, b: 255 }, brightness: 0.2,
      owner: `exact-restore-${index}`, controlRevision: registry.get(device.id).controlRevision }
    assert.equal((await send(frame)).body.applied, 1)
    await waitFor(() => bulb.color.brightness === percentToU16(20))
    const restore = { ...frame, restoring: true, rgb: { r: 255, g: 200, b: 180 }, brightness: expected.brightness / 65535 }
    if (index === 0) {
      const ip = registry.get(device.id).ip
      registry.patch(device.id, {ip:null})
      assert.equal((await send(restore)).status, 503, 'failed queueing must reach the restoration retry UI')
      assert.equal(registry.get(device.id).musicOwner, frame.owner, 'failed restoration keeps its owner and exact starting state')
      registry.patch(device.id, {ip})
    }
    assert.equal((await send(restore)).body.applied, 1)
    await waitFor(() => JSON.stringify(bulb.color) === JSON.stringify(expected))
    assert.deepEqual(bulb.color, expected, 'white mode, saturation, kelvin and brightness all survive Stop')
  }
})

test('owned Music restores Govee white with a temperature command', async () => {
  await api('/discover', {method:'POST'})
  const device = await waitFor(() => registry.list().find(d => d.brand === 'govee'))
  registry.claimControl(device.id)
  // The fake device's status fixture is RGB-only. Seed a known white reading,
  // then inspect the actual UDP command rather than that optimistic mirror.
  registry.patch(device.id, {kelvin:3500})
  const received = []
  const observe = buffer => received.push(JSON.parse(buffer.toString('utf8')).msg)
  strip.controlSocket.on('message', observe)
  const frame = {fixtureID:device.id,rgb:{r:0,g:0,b:255},brightness:0.2,
    owner:'restore-govee-white',controlRevision:registry.get(device.id).controlRevision}
  const send = state => api('/music/frame', {method:'POST',headers:{'Content-Type':'application/json',Origin:ORIGIN},
    body:JSON.stringify({states:[state]})})
  try {
    assert.equal((await send(frame)).body.applied, 1)
    await waitFor(() => received.some(message => message.cmd === 'colorwc' && message.data.color.b === 51))
    assert.equal((await send({...frame,restoring:true,brightness:0.6})).body.applied, 1)
    await waitFor(() => received.some(message => message.cmd === 'colorwc' && message.data.colorTemInKelvin === 3500))
    await waitFor(() => strip.brightness === 60)
  } finally {
    strip.controlSocket.off('message', observe)
  }
})

test('malformed Govee UDP discoveries cannot poison the registry', async () => {
  const localRegistry = new Registry()
  const sender = dgram.createSocket('udp4')
  await new Promise(resolve => sender.bind(0, '127.0.0.1', resolve))
  const client = new GoveeClient({ registry: localRegistry, responsePort: 0, controlPort: sender.address().port,
    joinMulticast: false, sweep: false })
  await client.start()
  try {
    const send = data => new Promise((resolve, reject) => sender.send(Buffer.from(JSON.stringify({ msg: { cmd: 'scan', data } })),
      client.socket.address().port, '127.0.0.1', err => err ? reject(err) : resolve()))
    await send({ ip: '127.0.0.1', device: 'bad-name', deviceName: {} })
    await send({ ip: '127.0.0.1', device: 'bad-sku', sku: [] })
    await send({ ip: '127.0.0.1', device: 'valid', deviceName: 'Desk' })
    await waitFor(() => localRegistry.get('govee:valid'))
    assert.equal(localRegistry.get('govee:bad-name'), null)
    assert.equal(localRegistry.get('govee:bad-sku'), null)
    assert.deepEqual(localRegistry.list().map(d => d.name), ['Desk'])
    assert.doesNotThrow(() => client.refresh())
  } finally {
    client.stop()
    sender.close()
  }
})

test('Host validation rejects rebinding for every HTTP method', async () => {
  const port = new URL(base).port
  for (const method of ['GET', 'HEAD', 'OPTIONS', 'POST']) {
    const result = await directRequest(base, method === 'POST' ? '/refresh' : '/state', {
      method, headers: { Host: `attacker.example:${port}`, Origin: `http://attacker.example:${port}` },
    })
    assert.equal(result.status, 403, method)
  }
  for (const host of [`localhost.evil.example:${port}`, `127.0.0.1.evil.example:${port}`, `attacker@localhost:${port}`,
    `localhost:${Number(port) + 1}`, `localhost:${port}/`, `localhost:${port}?x`, `localhost:${port}#x`]) {
    assert.equal((await directRequest(base, '/state', { headers: { Host: host } })).status, 403, host)
  }
  const wrongScheme = await directRequest(base, '/refresh', { method: 'POST',
    headers: { Host: `localhost:${port}`, Origin: `https://localhost:${port}` } })
  assert.equal(wrongScheme.status, 403, 'the HTTP bridge has no HTTPS own origin')
  assert.equal((await api('/health')).status, 200)
})

test('local aliases and the configured hostname retain their own HTTP origin', async () => {
  const localRegistry = new Registry()
  let refreshes = 0
  const inert = { refresh: () => { refreshes += 1 } }
  const localServer = createServer({ registry: localRegistry, lifx: inert, govee: inert, host: 'bridge.local',
    allowedOrigins: [ORIGIN, 'https://custom.example'], version: 'test' })
  await new Promise(resolve => localServer.listen(0, '127.0.0.1', resolve))
  const port = localServer.address().port
  const address = `http://127.0.0.1:${port}`
  try {
    for (const host of ['127.0.0.1', '127.1', 'LOCALHOST', 'localhost.', 'bridge.local']) {
      const canonical = new URL(`http://${host}:${port}`).origin
      assert.equal((await directRequest(address, '/refresh', { method: 'POST',
        headers: { Host: `${host}:${port}`, Origin: canonical } })).status, 202, host)
    }
    for (const origin of [ORIGIN, 'https://custom.example']) {
      assert.equal((await directRequest(address, '/refresh', { method: 'POST', headers: { Origin: origin } })).status, 202, origin)
    }
    assert.equal((await directRequest(address, '/refresh', { method: 'POST' })).status, 202, 'local scripts need no Origin')
    assert.equal(refreshes, 16)
  } finally {
    await new Promise(resolve => localServer.close(resolve))
  }
})

test('wildcard bind and allow-any-origin do not authorize arbitrary Hosts', async () => {
  const inert = { refresh: () => {} }
  const localServer = createServer({ registry: new Registry(), lifx: inert, govee: inert, host: '0.0.0.0',
    allowedOrigins: ['*'], version: 'test' })
  await new Promise(resolve => localServer.listen(0, '0.0.0.0', resolve))
  const port = localServer.address().port
  const address = `http://127.0.0.1:${port}`
  try {
    assert.equal((await directRequest(address, '/refresh', { method: 'POST', headers: { Origin: 'https://custom.example' } })).status, 202)
    assert.equal((await directRequest(address, '/state', { headers: { Host: `attacker.example:${port}` } })).status, 403)
  } finally {
    await new Promise(resolve => localServer.close(resolve))
  }
})

test('an IPv6 listener accepts its configured port and loopback alias', async t => {
  const inert = { refresh: () => {} }
  const localServer = createServer({ registry: new Registry(), lifx: inert, govee: inert, host: '::1',
    allowedOrigins: [], version: 'test' })
  try {
    await new Promise((resolve, reject) => {
      localServer.once('error', reject)
      localServer.listen(0, '::1', resolve)
    })
  } catch (err) {
    if (['EAFNOSUPPORT', 'EADDRNOTAVAIL'].includes(err.code)) return t.skip('IPv6 loopback is unavailable')
    throw err
  }
  const port = localServer.address().port
  const address = `http://[::1]:${port}`
  try {
    for (const host of ['[::1]', 'localhost']) {
      assert.equal((await directRequest(address, '/refresh', { method: 'POST',
        headers: { Host: `${host}:${port}`, Origin: `http://${host}:${port}` } })).status, 202)
    }
    assert.equal((await directRequest(address, '/health', { headers: { Host: `[::1]:${port + 1}` } })).status, 403)
  } finally {
    await new Promise(resolve => localServer.close(resolve))
  }
})

test('duplicate Host headers are rejected before the bridge routes a request', async () => {
  const port = Number(new URL(base).port)
  const response = await new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port })
    const chunks = []
    socket.on('error', reject)
    socket.on('data', chunk => chunks.push(chunk))
    socket.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    socket.on('connect', () => socket.end(`GET /state HTTP/1.1\r\nHost: localhost:${port}\r\nHost: attacker.example:${port}\r\nConnection: close\r\n\r\n`))
  })
  assert.match(response, /^HTTP\/1\.1 (400|403) /)
})

test('malformed request URLs return 400 and leave the server running', async () => {
  for (const path of ['//[', 'http://[']) {
    const response = await directRequest(base, path)
    assert.equal(response.status, 400, path)
    assert.match(response.text, /Invalid URL/)
    assert.equal((await api('/health')).status, 200, 'the next request still succeeds')
  }
})
