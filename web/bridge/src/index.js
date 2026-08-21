#!/usr/bin/env node
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { Registry } from './registry.js'
import { LifxClient } from './lifx-client.js'
import { GoveeClient } from './govee-client.js'
import { createServer } from './server.js'
import { isBuiltApp } from './static.js'
import { Store } from './store.js'
import { due, commandsFor } from './schedules.js'
import { runSchedule } from './actions.js'

const VERSION = '1.0.0'

// Only the published web app and local development origins may talk to the
// bridge by default; --allow-origin adds more, --allow-any-origin opens it up.
const DEFAULT_ORIGINS = [
  'https://seanpvera.github.io',
  'http://localhost:4173',
  'http://127.0.0.1:4173',
  'http://localhost:5173',
  'http://127.0.0.1:5173',
]

function parseArgs(argv) {
  const options = {
    port: 8765,
    host: '127.0.0.1',
    origins: [...DEFAULT_ORIGINS],
    discoverEvery: 15_000,
    refreshEvery: 5_000,
    quiet: false,
    serve: true,
    appDir: null,
  }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--port') options.port = Number(argv[++i])
    else if (arg === '--host') options.host = argv[++i]
    else if (arg === '--allow-origin') options.origins.push(argv[++i])
    else if (arg === '--allow-any-origin') options.origins = ['*']
    else if (arg === '--app-dir') options.appDir = argv[++i]
    else if (arg === '--no-serve') options.serve = false
    else if (arg === '--quiet') options.quiet = true
    else if (arg === '--help' || arg === '-h') options.help = true
  }
  return options
}

const options = parseArgs(process.argv.slice(2))

if (options.help) {
  console.log(`LumenDesk bridge ${VERSION}

Discovers LIFX and Govee lights on this network over UDP and exposes them to
the LumenDesk web app on a loopback HTTP API.

  --port <n>            listen port (default 8765)
  --host <addr>         bind address (default 127.0.0.1, loopback only)
  --allow-origin <url>  additional browser origin allowed to connect
  --allow-any-origin    allow any origin (development only)
  --app-dir <path>      directory of the built web client to serve
  --no-serve            expose only the API, do not serve the web client
  --quiet               suppress discovery logging
`)
  process.exit(0)
}

const log = options.quiet ? () => {} : (...args) => console.log('[bridge]', ...args)

const registry = new Registry()
const store = new Store({ log })
store.load()
const lifx = new LifxClient({ registry, log })
const govee = new GoveeClient({ registry, log })

await lifx.start()
await govee.start()

const here = path.dirname(fileURLToPath(import.meta.url))
const appDir = options.appDir
  ? path.resolve(options.appDir)
  : path.resolve(here, '..', '..', 'app', 'dist')
const staticDir = options.serve && isBuiltApp(appDir) ? appDir : null

const server = createServer({
  registry,
  lifx,
  govee,
  allowedOrigins: options.origins,
  version: VERSION,
  staticDir,
  store,
})

server.listen(options.port, options.host, () => {
  const base = `http://${options.host}:${options.port}`
  if (staticDir) {
    // Same-origin: no CORS, and no local-network permission prompt.
    console.log(`\n  LumenDesk is running. Open ${base}\n`)
  } else if (options.serve) {
    console.log(
      `\n  API only on ${base} — the web client is not built yet.\n` +
        `  Build it once to control your lights from this address:\n\n` +
        `      npm run app\n\n` +
        `  Until then the published page at\n` +
        `  https://seanpvera.github.io/LumenDesk/ can use this bridge, if your\n` +
        `  browser allows it to reach the local network.\n`,
    )
  } else {
    log(`API only on ${base} (--no-serve)`)
  }
  log(`allowed origins: ${options.origins.join(', ')}`)
  lifx.discover()
  govee.discover()
})

const discoverTimer = setInterval(() => {
  lifx.discover()
  govee.discover()
}, options.discoverEvery)

const refreshTimer = setInterval(() => {
  lifx.refresh()
  govee.refresh()
}, options.refreshEvery)

// Schedules run here rather than in the page, so they fire whether or not a
// browser is open. The window is half-open, so a missed tick still runs once.
let lastTick = new Date()
const scheduleTimer = setInterval(() => {
  const now = new Date()
  const decisions = due({ rooms: store.listRooms(), previous: lastTick, now })
  lastTick = now
  for (const { room, schedule } of decisions) {
    const result = runSchedule({ room, schedule, store, registry, lifx, govee, commandsFor })
    log(
      result.ran
        ? `schedule ${schedule.action} for ${room.name} ran on ${result.devices} light(s)`
        : `schedule ${schedule.action} for ${room.name} skipped: ${result.reason}`,
    )
  }
}, 20_000)

let known = 0
const reportTimer = setInterval(() => {
  const devices = registry.list().filter(d => d.reachable)
  if (devices.length !== known) {
    known = devices.length
    log(`${known} device(s) reachable: ${devices.map(d => d.name).join(', ') || 'none'}`)
  }
}, 2_000)

function shutdown() {
  clearInterval(discoverTimer)
  clearInterval(refreshTimer)
  clearInterval(reportTimer)
  clearInterval(scheduleTimer)
  lifx.stop()
  govee.stop()
  server.close(() => process.exit(0))
  setTimeout(() => process.exit(0), 500).unref()
}

process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
