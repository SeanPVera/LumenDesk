// Fake LIFX and Govee lights that speak the real wire protocols over UDP on
// loopback. They let the bridge be tested end to end — discovery, commands and
// state read-back — without physical hardware.
import dgram from 'node:dgram'
import http from 'node:http'
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
  constructor({ device = 'AA:BB:CC:DD:EE:FF:11:22', sku = 'H6159', name = 'Fake Strip',
                // What the device claims its address is. Real Govee firmware
                // bakes this at join time and keeps announcing it after a DHCP
                // renewal, so a test can point it somewhere it does not live.
                reportedIP = '127.0.0.1' } = {}) {
    this.reportedIP = reportedIP
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
          data: { ip: this.reportedIP, device: this.device, sku: this.sku, deviceName: this.name },
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

/**
 * A Nanoleaf Shapes controller on loopback HTTP, following the documented
 * routes closely enough to exercise the bridge: pairing, the full reading
 * with its layout, state, scene selection, static display and orientation.
 */
export class FakeShapesController {
  static serial = 'SHAPES123'
  static token = 'fakeShapesToken42'

  constructor() {
    this.requests = []
    this.pairingOpen = true
    this.model = 'NL42'
    this.state = { on: true, brightness: 80, hue: 20, sat: 80, ct: 3500, colorMode: 'effect' }
    this.select = 'Northern Lights'
    this.effects = ['Northern Lights', 'Evening']
    this.orientation = 240
    this.animData = null
    this.server = null
  }

  info() {
    return {
      name: 'Studio Shapes', serialNo: FakeShapesController.serial, model: this.model, firmwareVersion: '9.2.0',
      state: {
        on: { value: this.state.on }, brightness: { value: this.state.brightness, max: 100, min: 0 },
        hue: { value: this.state.hue, max: 360, min: 0 }, sat: { value: this.state.sat, max: 100, min: 0 },
        ct: { value: this.state.ct, max: 6500, min: 1200 }, colorMode: this.state.colorMode,
      },
      effects: { select: this.select, effectsList: this.effects },
      panelLayout: {
        globalOrientation: { value: this.orientation, max: 360, min: 0 },
        layout: { numPanels: 7, sideLength: 0, positionData: [
          { panelId: 5120, x: 0, y: 0, o: 0, shapeType: 7 },
          { panelId: 77, x: 100.5, y: 58.02, o: 0, shapeType: 7 },
          { panelId: 31000, x: -100.5, y: 58.02, o: 120, shapeType: 7 },
          { panelId: 1204, x: 67, y: -38.68, o: 0, shapeType: 9 },
          { panelId: 9, x: -67, y: -38.68, o: 0, shapeType: 9 },
          { panelId: 64001, x: 0, y: -96.7, o: 60, shapeType: 8 },
          { panelId: 0, x: -45, y: 105, o: 0, shapeType: 12 },
        ] },
      },
    }
  }

  listen() {
    return new Promise(resolve => {
      this.server = http.createServer(async (req, res) => {
        const chunks = []
        for await (const chunk of req) chunks.push(chunk)
        const text = Buffer.concat(chunks).toString('utf8')
        const body = text ? JSON.parse(text) : null
        this.requests.push({ method: req.method, path: req.url, body, at: performance.now() })
        const [status, payload] = this.#respond(req.method, req.url, body)
        res.writeHead(status, payload ? { 'Content-Type': 'application/json' } : {})
        res.end(payload ? JSON.stringify(payload) : undefined)
      })
      this.server.listen(0, '127.0.0.1', () => resolve(this.server.address().port))
    })
  }

  close() {
    this.server?.close()
  }

  #respond(method, url, body) {
    if (method === 'POST' && url === '/api/v1/new') {
      return this.pairingOpen ? [200, { auth_token: FakeShapesController.token }] : [403, null]
    }
    const prefix = `/api/v1/${FakeShapesController.token}`
    if (!url.startsWith(prefix)) return [401, null]
    const route = url.slice(prefix.length)
    if (method === 'GET' && route === '') return [200, this.info()]
    if (method === 'PUT' && route === '/state') {
      for (const [key, value] of Object.entries(body ?? {})) this.state[key] = value.value
      if (body?.hue || body?.sat) { this.state.colorMode = 'hs'; this.select = '*Solid*' }
      if (body?.ct) { this.state.colorMode = 'ct'; this.select = '*Solid*' }
      return [204, null]
    }
    if (method === 'PUT' && route === '/panelLayout') {
      const value = body?.globalOrientation?.value
      if (!Number.isInteger(value)) return [400, null]
      this.orientation = value
      return [204, null]
    }
    if (method === 'PUT' && route === '/effects') {
      if (typeof body?.select === 'string') {
        if (!this.effects.includes(body.select)) return [404, null]
        this.select = body.select
        this.state.colorMode = 'effect'
        return [204, null]
      }
      const write = body?.write
      if (write?.command === 'display' && write.animType === 'static') {
        this.select = '*Static*'
        this.state.colorMode = 'effect'
        this.animData = write.animData
        return [204, null]
      }
      if (write?.command === 'displayTemp') return [204, null]
      return [400, null]
    }
    return [404, null]
  }
}
