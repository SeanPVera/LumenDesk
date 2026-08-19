// Fake LIFX and Govee lights that speak the real wire protocols over UDP on
// loopback. They let the bridge be tested end to end — discovery, commands and
// state read-back — without physical hardware.
import dgram from 'node:dgram'
import * as lifx from '../src/lifx.js'
import * as govee from '../src/govee.js'

export class FakeLifxBulb {
  constructor({ mac = Buffer.from([0xd0, 0x73, 0xd5, 0x00, 0x0a, 0x01]), label = 'Fake Bulb' } = {}) {
    this.mac = mac
    this.label = label
    this.power = 0
    this.color = { hue: 0, saturation: 0, brightness: 32768, kelvin: 3500 }
    this.received = []
    this.socket = null
  }

  listen() {
    return new Promise(resolve => {
      this.socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
      this.socket.on('message', (msg, rinfo) => this.#handle(msg, rinfo))
      this.socket.bind(0, '127.0.0.1', () => resolve(this.socket.address().port))
    })
  }

  close() {
    this.socket?.close()
  }

  #reply(type, payload, rinfo, source, sequence) {
    const pkt = lifx.packet({ type, source, target: this.mac, payload, sequence })
    this.socket.send(pkt, rinfo.port, rinfo.address)
  }

  #lightStatePayload() {
    const p = Buffer.alloc(52)
    p.writeUInt16LE(this.color.hue, 0)
    p.writeUInt16LE(this.color.saturation, 2)
    p.writeUInt16LE(this.color.brightness, 4)
    p.writeUInt16LE(this.color.kelvin, 6)
    p.writeUInt16LE(this.power, 10)
    Buffer.from(this.label).copy(p, 12)
    return p
  }

  #handle(msg, rinfo) {
    const header = lifx.parse(msg)
    if (!header) return
    this.received.push(header.type)

    if (header.type === lifx.Message.getService) {
      const payload = Buffer.alloc(5)
      payload.writeUInt8(1, 0) // service = UDP
      payload.writeUInt32LE(lifx.PORT, 1)
      this.#reply(lifx.Message.stateService, payload, rinfo, header.source, header.sequence)
      return
    }

    if (header.type === lifx.Message.setLightPower) {
      this.power = header.payload.readUInt16LE(0)
    }

    if (header.type === lifx.Message.lightSetColor) {
      this.color = {
        hue: header.payload.readUInt16LE(1),
        saturation: header.payload.readUInt16LE(3),
        brightness: header.payload.readUInt16LE(5),
        kelvin: header.payload.readUInt16LE(7),
      }
    }

    // Real bulbs answer LightGet, and echo state after a set.
    this.#reply(
      lifx.Message.lightState,
      this.#lightStatePayload(),
      rinfo,
      header.source,
      header.sequence,
    )
  }
}

export class FakeGoveeDevice {
  constructor({ device = 'AA:BB:CC:DD:EE:FF:11:22', sku = 'H6159', name = 'Fake Strip' } = {}) {
    this.device = device
    this.sku = sku
    this.name = name
    this.onOff = 0
    this.brightness = 50
    this.color = { r: 255, g: 255, b: 255 }
    this.received = []
    this.discoverySocket = null
    this.controlSocket = null
    this.bridgeResponsePort = null
  }

  /** @param bridgeResponsePort where the bridge listens for our replies. */
  async listen(bridgeResponsePort) {
    this.bridgeResponsePort = bridgeResponsePort
    const bind = (socket, port) =>
      new Promise(resolve => socket.bind(port, '127.0.0.1', () => resolve(socket.address().port)))

    this.discoverySocket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    this.discoverySocket.on('message', msg => this.#handle(msg))
    this.controlSocket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    this.controlSocket.on('message', msg => this.#handle(msg))

    const discoveryPort = await bind(this.discoverySocket, 0)
    const controlPort = await bind(this.controlSocket, 0)
    return { discoveryPort, controlPort }
  }

  close() {
    this.discoverySocket?.close()
    this.controlSocket?.close()
  }

  #send(body) {
    this.controlSocket.send(Buffer.from(JSON.stringify(body)), this.bridgeResponsePort, '127.0.0.1')
  }

  #handle(msg) {
    let parsed
    try {
      parsed = JSON.parse(msg.toString('utf8'))
    } catch {
      return
    }
    const cmd = parsed?.msg?.cmd
    const data = parsed?.msg?.data ?? {}
    this.received.push(cmd)

    if (cmd === 'scan') {
      this.#send({
        msg: {
          cmd: 'scan',
          data: { ip: '127.0.0.1', device: this.device, sku: this.sku, deviceName: this.name },
        },
      })
      return
    }
    if (cmd === 'turn') this.onOff = data.value
    if (cmd === 'brightness') this.brightness = data.value
    if (cmd === 'colorwc' && data.color) this.color = data.color

    if (cmd === 'devStatus' || cmd === 'turn' || cmd === 'brightness' || cmd === 'colorwc') {
      this.#send({
        msg: {
          cmd: 'devStatus',
          data: {
            onOff: this.onOff,
            brightness: this.brightness,
            color: this.color,
            colorTemInKelvin: 0,
          },
        },
      })
    }
  }
}
