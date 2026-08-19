// LIFX LAN protocol primitives, ported byte-for-byte from
// LumenDesk/Services/LIFX/LIFXProtocol.swift. Packets are little-endian with a
// fixed 36-byte header followed by a per-message payload.
// https://lan.developer.lifx.com/docs/header-description

export const PORT = 56700
export const BROADCAST_ADDRESS = '255.255.255.255'
export const HEADER_SIZE = 36

export const Message = {
  getService: 2,
  stateService: 3,
  stateLabel: 25,
  getVersion: 32,
  stateVersion: 33,
  setLightPower: 117,
  stateLightPower: 118,
  lightGet: 101,
  lightSetColor: 102,
  lightState: 107,
}

/**
 * Build a LIFX LAN packet.
 * @param target 6-byte MAC Buffer; empty for a broadcast (tagged) message.
 */
export function packet({
  type,
  source,
  target = Buffer.alloc(0),
  payload = Buffer.alloc(0),
  sequence = 0,
  resRequired = false,
  ackRequired = false,
}) {
  const size = HEADER_SIZE + payload.length
  const buf = Buffer.alloc(size)

  buf.writeUInt16LE(size, 0)

  // protocol(12 bits = 1024) | addressable | tagged, as a little-endian uint16.
  let flags = 1024 | 0x1000
  if (target.length === 0) flags |= 0x2000
  buf.writeUInt16LE(flags, 2)

  buf.writeUInt32LE(source >>> 0, 4)

  // 6-byte MAC padded to 8 bytes; the remaining header bytes stay zero.
  target.subarray(0, 6).copy(buf, 8)

  let respFlags = 0
  if (resRequired) respFlags |= 0x01
  if (ackRequired) respFlags |= 0x02
  buf.writeUInt8(respFlags, 22)
  buf.writeUInt8(sequence, 23)

  buf.writeUInt16LE(type, 32)

  payload.copy(buf, HEADER_SIZE)
  return buf
}

export function parse(data) {
  if (data.length < HEADER_SIZE) return null
  const size = data.readUInt16LE(0)
  if (size < HEADER_SIZE || size !== data.length) return null
  return {
    size,
    source: data.readUInt32LE(4),
    target: Buffer.from(data.subarray(8, 14)),
    sequence: data.readUInt8(23),
    type: data.readUInt16LE(32),
    payload: Buffer.from(data.subarray(HEADER_SIZE, size)),
  }
}

// MARK: payload builders

export function setColorPayload({ hue, saturation, brightness, kelvin }, durationMS = 250) {
  const p = Buffer.alloc(13)
  p.writeUInt8(0, 0) // reserved
  p.writeUInt16LE(hue, 1)
  p.writeUInt16LE(saturation, 3)
  p.writeUInt16LE(brightness, 5)
  p.writeUInt16LE(kelvin, 7)
  p.writeUInt32LE(durationMS, 9)
  return p
}

export function setPowerPayload(on, durationMS = 250) {
  const p = Buffer.alloc(6)
  p.writeUInt16LE(on ? 65535 : 0, 0)
  p.writeUInt32LE(durationMS, 2)
  return p
}

// MARK: payload parsers

export function parseLightState(payload) {
  if (payload.length < 52) return null
  const labelBytes = payload.subarray(12, 44)
  const end = labelBytes.indexOf(0)
  return {
    color: {
      hue: payload.readUInt16LE(0),
      saturation: payload.readUInt16LE(2),
      brightness: payload.readUInt16LE(4),
      kelvin: payload.readUInt16LE(6),
    },
    // payload[8..10] is reserved
    power: payload.readUInt16LE(10),
    label: labelBytes.subarray(0, end === -1 ? labelBytes.length : end).toString('utf8'),
  }
}

export function parseVersion(payload) {
  if (payload.length < 12) return null
  return { vendorID: payload.readUInt32LE(0), productID: payload.readUInt32LE(4) }
}

export function parseStateService(payload) {
  if (payload.length < 5) return null
  return { service: payload.readUInt8(0), port: payload.readUInt32LE(1) }
}

/** Format a 6-byte MAC target as the `lifx:` device id suffix. */
export function macToID(target) {
  return [...target.subarray(0, 6)].map(b => b.toString(16).padStart(2, '0')).join('')
}

export function idToMAC(id) {
  const buf = Buffer.alloc(6)
  for (let i = 0; i < 6; i += 1) buf[i] = parseInt(id.slice(i * 2, i * 2 + 2), 16) || 0
  return buf
}
