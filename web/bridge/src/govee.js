// Govee LAN API, ported from LumenDesk/Services/Govee/GoveeProtocol.swift.
// The user must enable "LAN Control" in the Govee Home app on each bulb.
// https://app-h5.govee.com/user-manual/wlan-guide

export const MULTICAST_GROUP = '239.255.255.250'
export const DISCOVERY_PORT = 4001
export const RESPONSE_PORT = 4002
export const CONTROL_PORT = 4003

export function scanRequest() {
  return Buffer.from('{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}')
}

export function statusRequest() {
  return Buffer.from('{"msg":{"cmd":"devStatus","data":{}}}')
}

export function turnRequest(on) {
  return Buffer.from(`{"msg":{"cmd":"turn","data":{"value":${on ? 1 : 0}}}}`)
}

export function brightnessRequest(value) {
  const clamped = Math.max(0, Math.min(100, Math.round(value)))
  return Buffer.from(`{"msg":{"cmd":"brightness","data":{"value":${clamped}}}}`)
}

/** Set color or color temperature. If kelvin > 0, the bulb ignores RGB. */
export function colorRequest({ r, g, b, kelvin = 0 }) {
  const c = v => Math.max(0, Math.min(255, Math.round(v)))
  return Buffer.from(
    `{"msg":{"cmd":"colorwc","data":{"color":{"r":${c(r)},"g":${c(g)},"b":${c(b)}},` +
      `"colorTemInKelvin":${Math.max(0, Math.round(kelvin))}}}}`,
  )
}

// Command markers avoid a full JSON decode for every routine heartbeat, the
// same short-circuit the Swift client uses.
const SCAN_MARKER = '"scan"'
const STATUS_MARKER = '"devStatus"'

function decode(data) {
  try {
    return JSON.parse(data.toString('utf8'))
  } catch {
    return null
  }
}

export function decodeScanResponse(data) {
  const text = data.toString('utf8')
  if (!text.includes(SCAN_MARKER)) return null
  const parsed = decode(data)
  if (parsed?.msg?.cmd !== 'scan') return null
  const d = parsed.msg.data
  if (!d?.ip || !d?.device) return null
  return { ip: d.ip, device: d.device, sku: d.sku ?? null, deviceName: d.deviceName ?? null }
}

export function decodeStatusResponse(data) {
  const text = data.toString('utf8')
  if (!text.includes(STATUS_MARKER)) return null
  const parsed = decode(data)
  if (parsed?.msg?.cmd !== 'devStatus') return null
  const d = parsed.msg.data
  if (!d) return null
  return {
    onOff: d.onOff ?? 0,
    brightness: d.brightness ?? 0,
    color: d.color ?? null,
    colorTemInKelvin: d.colorTemInKelvin ?? null,
  }
}
