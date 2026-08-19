// These assertions mirror LumenDeskTests/ProtocolTests.swift so the bridge and
// the native app put identical bytes on the wire.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import * as lifx from '../src/lifx.js'
import * as govee from '../src/govee.js'

test('LIFX packet encoding matches the Swift encoder', () => {
  const target = Buffer.from([0xd0, 0x73, 0xd5, 0x12, 0x34, 0x56])
  const payload = lifx.setPowerPayload(true, 500)
  const pkt = lifx.packet({
    type: lifx.Message.setLightPower,
    source: 0x12345678,
    target,
    payload,
    sequence: 7,
    resRequired: true,
    ackRequired: true,
  })

  assert.equal(pkt.length, lifx.HEADER_SIZE + payload.length)
  assert.equal(pkt.readUInt16LE(0), pkt.length)
  assert.equal(pkt.readUInt16LE(2), 0x1400) // protocol|addressable, not tagged
  assert.equal(pkt.readUInt32LE(4), 0x12345678)
  assert.deepEqual(pkt.subarray(8, 14), target)
  assert.equal(pkt.readUInt8(14), 0) // MAC padded to 8 bytes
  assert.equal(pkt.readUInt8(15), 0)
  assert.equal(pkt.readUInt8(22), 0x03) // res|ack required
  assert.equal(pkt.readUInt8(23), 7)
  assert.equal(pkt.readUInt16LE(32), lifx.Message.setLightPower)
  assert.deepEqual(pkt.subarray(-payload.length), payload)
})

test('LIFX broadcast packets set the tagged bit', () => {
  const pkt = lifx.packet({ type: lifx.Message.getService, source: 1 })
  assert.equal(pkt.readUInt16LE(2), 0x3400) // tagged adds 0x2000
  assert.equal(pkt.length, lifx.HEADER_SIZE)
  assert.deepEqual(pkt.subarray(8, 16), Buffer.alloc(8))
})

test('LIFX setPower and setColor payload layouts', () => {
  const off = lifx.setPowerPayload(false, 250)
  assert.equal(off.readUInt16LE(0), 0)
  assert.equal(off.readUInt32LE(2), 250)
  const on = lifx.setPowerPayload(true, 500)
  assert.equal(on.readUInt16LE(0), 65535)

  const color = lifx.setColorPayload(
    { hue: 10000, saturation: 20000, brightness: 30000, kelvin: 4000 },
    400,
  )
  assert.equal(color.length, 13)
  assert.equal(color.readUInt8(0), 0) // reserved
  assert.equal(color.readUInt16LE(1), 10000)
  assert.equal(color.readUInt16LE(3), 20000)
  assert.equal(color.readUInt16LE(5), 30000)
  assert.equal(color.readUInt16LE(7), 4000)
  assert.equal(color.readUInt32LE(9), 400)
})

test('LIFX response decoding round-trips a LightState', () => {
  const payload = Buffer.alloc(52)
  payload.writeUInt16LE(10000, 0)
  payload.writeUInt16LE(20000, 2)
  payload.writeUInt16LE(30000, 4)
  payload.writeUInt16LE(4000, 6)
  payload.writeUInt16LE(0xffff, 10)
  Buffer.from('Desk Lamp').copy(payload, 12)

  const datagram = lifx.packet({
    type: lifx.Message.lightState,
    source: 99,
    target: Buffer.from([1, 2, 3, 4, 5, 6]),
    payload,
    sequence: 4,
  })

  const header = lifx.parse(datagram)
  assert.equal(header.size, datagram.length)
  assert.equal(header.source, 99)
  assert.equal(header.sequence, 4)
  assert.equal(header.type, lifx.Message.lightState)

  const state = lifx.parseLightState(header.payload)
  assert.deepEqual(state.color, { hue: 10000, saturation: 20000, brightness: 30000, kelvin: 4000 })
  assert.equal(state.power, 0xffff)
  assert.equal(state.label, 'Desk Lamp') // NUL padding trimmed
})

test('LIFX parse rejects truncated and mis-sized datagrams', () => {
  assert.equal(lifx.parse(Buffer.alloc(10)), null)
  const pkt = lifx.packet({ type: lifx.Message.getService, source: 1 })
  pkt.writeUInt16LE(999, 0) // size field disagrees with actual length
  assert.equal(lifx.parse(pkt), null)
})

test('LIFX MAC id helpers round-trip', () => {
  const mac = Buffer.from([0xd0, 0x73, 0xd5, 0x00, 0x0a, 0xff])
  assert.equal(lifx.macToID(mac), 'd073d5000aff')
  assert.deepEqual(lifx.idToMAC('d073d5000aff'), mac)
})

test('Govee command payloads match the Swift strings', () => {
  assert.equal(
    govee.scanRequest().toString(),
    '{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}',
  )
  assert.equal(govee.statusRequest().toString(), '{"msg":{"cmd":"devStatus","data":{}}}')
  assert.equal(govee.turnRequest(true).toString(), '{"msg":{"cmd":"turn","data":{"value":1}}}')
  assert.equal(govee.turnRequest(false).toString(), '{"msg":{"cmd":"turn","data":{"value":0}}}')
  assert.equal(
    govee.brightnessRequest(55).toString(),
    '{"msg":{"cmd":"brightness","data":{"value":55}}}',
  )
  assert.equal(
    govee.colorRequest({ r: 255, g: 128, b: 0 }).toString(),
    '{"msg":{"cmd":"colorwc","data":{"color":{"r":255,"g":128,"b":0},"colorTemInKelvin":0}}}',
  )
})

test('Govee clamps out-of-range values like the Swift encoder', () => {
  assert.match(govee.brightnessRequest(999).toString(), /"value":100}/)
  assert.match(govee.brightnessRequest(-5).toString(), /"value":0}/)
  assert.match(govee.colorRequest({ r: 999, g: -3, b: 12 }).toString(), /"r":255,"g":0,"b":12/)
})

test('Govee decodes scan and status responses, ignoring foreign traffic', () => {
  const scan = govee.decodeScanResponse(
    Buffer.from(
      '{"msg":{"cmd":"scan","data":{"ip":"192.168.1.50","device":"AA:BB","sku":"H6159","deviceName":"Strip"}}}',
    ),
  )
  assert.deepEqual(scan, { ip: '192.168.1.50', device: 'AA:BB', sku: 'H6159', deviceName: 'Strip' })

  const status = govee.decodeStatusResponse(
    Buffer.from(
      '{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":80,"color":{"r":1,"g":2,"b":3},"colorTemInKelvin":0}}}',
    ),
  )
  assert.equal(status.onOff, 1)
  assert.equal(status.brightness, 80)
  assert.deepEqual(status.color, { r: 1, g: 2, b: 3 })

  // Unrelated SSDP chatter shares the multicast group and must not decode.
  assert.equal(govee.decodeScanResponse(Buffer.from('NOTIFY * HTTP/1.1')), null)
  assert.equal(govee.decodeScanResponse(Buffer.from('{"msg":{"cmd":"devStatus"}}')), null)
  assert.equal(govee.decodeStatusResponse(Buffer.from('not json at all')), null)
})
