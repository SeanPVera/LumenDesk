import dgram from 'node:dgram'
import * as lifx from './lifx.js'
import { hsbkToRgb, percentToU16, rgbToHsv, u16ToPercent } from './color.js'

// Discovery broadcasts GetService on 56700; every responder is then asked for
// its full light state. Devices reply to the port we sent from, so one
// ephemeral socket serves both directions.
export class LifxClient {
  constructor({
    registry,
    log = () => {},
    discoveryAddress = lifx.BROADCAST_ADDRESS,
    port = lifx.PORT,
  }) {
    this.registry = registry
    this.log = log
    this.discoveryAddress = discoveryAddress
    this.port = port
    this.socket = null
    this.source = 0x4c554d45 // "LUME"
    this.sequence = 0
    // MAC target per device id, needed to address unicast commands.
    this.targets = new Map()
  }

  start() {
    return new Promise((resolve, reject) => {
      const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
      socket.on('error', err => {
        this.log(`LIFX socket error: ${err.message}`)
        reject(err)
      })
      socket.on('message', (msg, rinfo) => this.#handle(msg, rinfo))
      socket.bind(0, () => {
        socket.setBroadcast(true)
        this.socket = socket
        resolve()
      })
    })
  }

  stop() {
    this.socket?.close()
    this.socket = null
  }

  discover() {
    if (!this.socket) return
    const pkt = lifx.packet({
      type: lifx.Message.getService,
      source: this.source,
      sequence: this.#nextSequence(),
    })
    this.socket.send(pkt, this.port, this.discoveryAddress, err => {
      if (err) this.log(`LIFX discovery send failed: ${err.message}`)
    })
  }

  /** Ask every known device for its current colour/power/label. */
  refresh() {
    for (const [id, target] of this.targets) {
      const device = this.registry.get(id)
      if (device?.ip) this.#send(lifx.Message.lightGet, target, device.ip)
    }
  }

  setPower(device, on) {
    const target = this.targets.get(device.id)
    if (!target || !device.ip) return false
    this.#send(lifx.Message.setLightPower, target, device.ip, lifx.setPowerPayload(on))
    return true
  }

  /** Brightness and colour share one SetColor message, so unchanged channels
   *  are carried over from the device's last known HSBK. */
  setColor(device, { rgb, brightnessPercent, kelvin, hsbk }) {
    const target = this.targets.get(device.id)
    if (!target || !device.ip) return false

    // A scene restores the exact captured HSBK. Going through RGB would lose
    // the distinction between a saturated colour and a white at some kelvin,
    // because a LIFX device always reports both.
    if (hsbk) {
      this.#send(lifx.Message.lightSetColor, target, device.ip, lifx.setColorPayload(hsbk))
      return true
    }

    const current = device.hsbk ?? { hue: 0, saturation: 0, brightness: 32768, kelvin: 3500 }

    let { hue, saturation } = current
    if (rgb) {
      const hsv = rgbToHsv(rgb)
      hue = Math.round((hsv.h / 360) * 65535)
      saturation = Math.round(hsv.s * 65535)
    }
    if (kelvin) saturation = 0 // white mode: kelvin only applies when unsaturated

    const brightness =
      brightnessPercent === undefined ? current.brightness : percentToU16(brightnessPercent)

    const next = { hue, saturation, brightness, kelvin: kelvin || current.kelvin || 3500 }
    this.#send(lifx.Message.lightSetColor, target, device.ip, lifx.setColorPayload(next))
    return true
  }

  #nextSequence() {
    this.sequence = (this.sequence + 1) % 256
    return this.sequence
  }

  #send(type, target, ip, payload) {
    if (!this.socket) return
    const pkt = lifx.packet({
      type,
      source: this.source,
      target,
      payload,
      sequence: this.#nextSequence(),
    })
    this.socket.send(pkt, this.port, ip, err => {
      if (err) this.log(`LIFX send to ${ip} failed: ${err.message}`)
    })
  }

  #handle(msg, rinfo) {
    const header = lifx.parse(msg)
    if (!header || header.source !== this.source) return

    const id = `lifx:${lifx.macToID(header.target)}`
    this.targets.set(id, header.target)

    if (header.type === lifx.Message.stateService) {
      // Announce-only; ask for the details we actually render.
      this.registry.upsert(id, { ip: rinfo.address })
      this.#send(lifx.Message.lightGet, header.target, rinfo.address)
      return
    }

    if (header.type === lifx.Message.lightState) {
      const state = lifx.parseLightState(header.payload)
      if (!state) return
      this.registry.upsert(id, {
        ip: rinfo.address,
        name: state.label || id,
        power: state.power > 0,
        brightness: u16ToPercent(state.color.brightness),
        color: hsbkToRgb(state.color),
        kelvin: state.color.kelvin,
        hsbk: state.color,
      })
    }
  }
}
