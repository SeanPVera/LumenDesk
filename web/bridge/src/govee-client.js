import dgram from 'node:dgram'
import * as govee from './govee.js'
import { clampPercent } from './color.js'
import { describeReport, listInterfaces, probeSubnets, sendTo, toDotted } from './net.js'

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
    sweep = true,
    broadcastRounds = 3,
  }) {
    this.registry = registry
    this.log = log
    this.discoveryAddress = discoveryAddress
    this.discoveryPort = discoveryPort
    this.responsePort = responsePort
    this.controlPort = controlPort
    this.joinMulticast = joinMulticast
    // Off in tests, where discovery is pointed at a fake device on loopback and
    // a real subnet sweep would spray the machine running the suite.
    this.sweep = sweep
    // Wi-Fi broadcast is unacknowledged and a device in power save drops it,
    // so the round is repeated. Tests use one, against a loopback fake.
    this.broadcastRounds = broadcastRounds
    /** Interface addresses we already hold a multicast membership on. */
    this.joined = new Set()
    /** What the last discovery pass put on the wire. */
    this.lastProbe = null
    /** In-flight pass, so a rescan joins it instead of stacking sweeps. */
    this.discovering = null
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
        socket.setBroadcast(true)
        try {
          // A baseline join on the default multicast interface; `discover`
          // adds one per real interface once it can enumerate them.
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

  /**
   * One discovery pass. Multicast is sent once per interface with the outgoing
   * interface pinned: left unset, the OS sends the scan out whichever
   * interface the default route names, which on a host running a VPN or a
   * container bridge is reliably not the one the lights are on. Devices also
   * answer a scan sent to their own address or the subnet broadcast, which is
   * what carries discovery on networks that filter multicast.
   */
  discover() {
    if (!this.socket) return Promise.resolve(null)
    if (this.discovering) return this.discovering
    this.discovering = this.#runDiscovery().finally(() => { this.discovering = null })
    return this.discovering
  }

  async #runDiscovery() {
    const req = govee.scanRequest()
    const interfaces = this.sweep ? listInterfaces() : []
    let multicastSent = 0
    let multicastFailed = 0
    let multicastError = null

    if (this.joinMulticast && interfaces.length) {
      for (const item of interfaces) {
        const address = toDotted(item.address)
        if (!this.joined.has(address)) {
          try {
            this.socket.addMembership(this.discoveryAddress, address)
            this.joined.add(address)
          } catch {
            // Already joined, or the interface refuses membership. The
            // directed broadcast and the sweep do not depend on it.
          }
        }
        try {
          this.socket.setMulticastInterface(address)
        } catch {
          // Keep going for the same reason.
        }
        const err = await sendTo(this.socket, req, this.discoveryPort, this.discoveryAddress)
        if (err) {
          multicastFailed += 1
          multicastError = err.message ?? String(err)
        } else {
          multicastSent += 1
        }
      }
      try {
        this.socket.setMulticastInterface('0.0.0.0')
      } catch {
        // Restoring the default is best effort.
      }
    }

    const report = await probeSubnets(this.socket, req, this.discoveryPort, {
      interfaces,
      // With no interfaces to enumerate (tests, or a host with no IPv4
      // network) this is the only target left, so it must still be sent.
      extraTargets: interfaces.length && this.joinMulticast ? [] : [this.discoveryAddress],
      broadcastRounds: this.broadcastRounds,
    })
    report.sent += multicastSent
    report.failed += multicastFailed
    if (!report.lastError) report.lastError = multicastError
    this.lastProbe = report
    if (!report.sent) this.log(`Govee discovery reached nothing: ${describeReport(report)}`)
    return report
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
      // Use the address the datagram actually came from, not the one the
      // device announces. Govee firmware bakes that field at join time and
      // keeps announcing a stale address after a DHCP renewal, which sent
      // every command to a dead IP and came back EHOSTUNREACH while discovery
      // still reported the light as present. The LIFX client has always used
      // the source address; this makes Govee agree.
      const ip = rinfo?.address || scan.ip
      if (scan.ip && scan.ip !== ip) {
        this.log(`Govee device reports ${scan.ip} but answered from ${ip}; using ${ip}`)
      }
      this.registry.upsert(id, {
        ip,
        name: scan.deviceName || scan.sku || id,
        sku: scan.sku,
      })
      this.#enqueue(ip, 'devStatus', govee.statusRequest())
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
