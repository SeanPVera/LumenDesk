import dgram from 'node:dgram'
import * as govee from './govee.js'
import { clampPercent } from './color.js'

// Govee firmware drops back-to-back datagrams, so — exactly as GoveeClient.swift
// does — commands are paced at least MIN_GAP_MS apart per device and queued
// same-kind payloads collapse to the newest value.
const MIN_GAP_MS = 100

export class GoveeClient {
  constructor({
    registry,
    log = () => {},
    discoveryAddress = govee.MULTICAST_GROUP,
    discoveryPort = govee.DISCOVERY_PORT,
    responsePort = govee.RESPONSE_PORT,
    controlPort = govee.CONTROL_PORT,
    joinMulticast = true,
  }) {
    this.registry = registry
    this.log = log
    this.discoveryAddress = discoveryAddress
    this.discoveryPort = discoveryPort
    this.responsePort = responsePort
    this.controlPort = controlPort
    this.joinMulticast = joinMulticast
    this.socket = null
    this.queues = new Map() // ip -> { pending: Map<kind, Buffer>, timer, lastSent }
  }

  start() {
    return new Promise(resolve => {
      // Devices send scan replies and status to 4002, so we must own that port.
      const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
      socket.on('error', err => this.log(`Govee socket error: ${err.message}`))
      socket.on('message', (msg, rinfo) => this.#handle(msg, rinfo))
      socket.bind(this.responsePort, () => {
        try {
          if (this.joinMulticast) socket.addMembership(this.discoveryAddress)
        } catch (err) {
          // Without multicast membership discovery still works on networks that
          // forward the reply unicast; log and continue rather than dying.
          this.log(`Govee multicast join failed: ${err.message}`)
        }
        this.socket = socket
        resolve()
      })
    })
  }

  stop() {
    for (const q of this.queues.values()) clearTimeout(q.timer)
    this.queues.clear()
    this.socket?.close()
    this.socket = null
  }

  discover() {
    if (!this.socket) return
    const req = govee.scanRequest()
    this.socket.send(req, this.discoveryPort, this.discoveryAddress, err => {
      if (err) this.log(`Govee discovery send failed: ${err.message}`)
    })
  }

  refresh() {
    for (const device of this.registry.list()) {
      if (device.brand === 'govee' && device.ip) {
        this.#enqueue(device.ip, 'devStatus', govee.statusRequest())
      }
    }
  }

  setPower(device, on) {
    if (!device.ip) return false
    this.#enqueue(device.ip, 'turn', govee.turnRequest(on))
    return true
  }

  setBrightness(device, percent) {
    if (!device.ip) return false
    this.#enqueue(device.ip, 'brightness', govee.brightnessRequest(clampPercent(percent)))
    return true
  }

  setColor(device, { rgb, kelvin }) {
    if (!device.ip) return false
    this.#enqueue(
      device.ip,
      'colorwc',
      govee.colorRequest({ ...(rgb ?? { r: 0, g: 0, b: 0 }), kelvin: kelvin ?? 0 }),
    )
    return true
  }

  /** Coalesce by command kind, then drain no faster than one per MIN_GAP_MS. */
  #enqueue(ip, kind, payload) {
    let queue = this.queues.get(ip)
    if (!queue) {
      queue = { pending: new Map(), timer: null, lastSent: 0 }
      this.queues.set(ip, queue)
    }
    queue.pending.set(kind, payload)
    this.#drain(ip)
  }

  #drain(ip) {
    const queue = this.queues.get(ip)
    if (!queue || queue.timer || queue.pending.size === 0) return

    const wait = Math.max(0, queue.lastSent + MIN_GAP_MS - Date.now())
    queue.timer = setTimeout(() => {
      queue.timer = null
      const [kind, payload] = queue.pending.entries().next().value
      queue.pending.delete(kind)
      queue.lastSent = Date.now()
      this.socket?.send(payload, this.controlPort, ip, err => {
        if (err) this.log(`Govee send to ${ip} failed: ${err.message}`)
      })
      this.#drain(ip)
    }, wait)
  }

  #handle(msg, rinfo) {
    const scan = govee.decodeScanResponse(msg)
    if (scan) {
      const id = `govee:${scan.device}`
      this.registry.upsert(id, {
        ip: scan.ip,
        name: scan.deviceName || scan.sku || id,
        sku: scan.sku,
      })
      this.#enqueue(scan.ip, 'devStatus', govee.statusRequest())
      return
    }

    const status = govee.decodeStatusResponse(msg)
    if (!status) return
    // devStatus carries no device id, so it is matched by source address.
    const device = this.registry
      .list()
      .find(d => d.brand === 'govee' && d.ip === rinfo.address)
    if (!device) return
    this.registry.upsert(device.id, {
      power: status.onOff > 0,
      brightness: clampPercent(status.brightness),
      color: status.color ?? device.color,
      kelvin: status.colorTemInKelvin || null,
    })
  }
}
