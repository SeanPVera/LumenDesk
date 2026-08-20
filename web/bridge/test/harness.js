// Dev harness: runs the real bridge against fake lights on loopback so the web
// client can be exercised end to end without hardware.
//   node test/harness.js [--port 8765]
import http from 'node:http'
import { Registry } from '../src/registry.js'
import { LifxClient } from '../src/lifx-client.js'
import { GoveeClient } from '../src/govee-client.js'
import { createServer } from '../src/server.js'
import { FakeLifxBulb, FakeGoveeDevice } from './fake-devices.js'

const portArg = process.argv.indexOf('--port')
const PORT = portArg === -1 ? 8765 : Number(process.argv[portArg + 1])

const bulb = new FakeLifxBulb({ label: 'Desk Lamp' })
const bulbPort = await bulb.listen()

const registry = new Registry()
const lifx = new LifxClient({ registry, discoveryAddress: '127.0.0.1', port: bulbPort })
const govee = new GoveeClient({
  registry,
  discoveryAddress: '127.0.0.1',
  responsePort: 0,
  joinMulticast: false,
})
await lifx.start()
await govee.start()

const strip = new FakeGoveeDevice({ name: 'Living Room Strip' })
const ports = await strip.listen(govee.socket.address().port)
govee.discoveryPort = ports.discoveryPort
govee.controlPort = ports.controlPort

const server = createServer({
  registry,
  lifx,
  govee,
  allowedOrigins: ['*'],
  version: 'harness',
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[harness] bridge on http://127.0.0.1:${PORT} with 2 fake lights`)
  lifx.discover()
  govee.discover()
})

setInterval(() => {
  lifx.discover()
  govee.discover()
}, 5000)
setInterval(() => {
  lifx.refresh()
  govee.refresh()
}, 2000)

// A separate inspector port exposes the fake devices' true internal state, so
// a driving test can assert the light really changed rather than trusting the
// bridge's own view of it.
http
  .createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(
      JSON.stringify({
        lifx: { power: bulb.power, color: bulb.color, label: bulb.label },
        govee: { onOff: strip.onOff, brightness: strip.brightness, color: strip.color },
      }),
    )
  })
  .listen(PORT + 1, '127.0.0.1', () => console.log(`[harness] fake state on ${PORT + 1}`))

process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))
