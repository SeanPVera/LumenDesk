import http from 'node:http'
import { clampPercent } from './color.js'
import { serveStatic } from './static.js'
import { applyScene, snapshot } from './actions.js'
import { ACTIONS } from './schedules.js'

// A page served from https://<user>.github.io may call this bridge because
// 127.0.0.1 is a "potentially trustworthy" origin, exempt from mixed content
// blocking.
//
// Reaching it is then gated by the browser. Chrome 142+ ships Local Network
// Access, which asks the *user* for permission and replaced the earlier
// Private Network Access design; nothing the server sends can grant it. The
// Access-Control-Allow-Private-Network answer below is kept only for older
// Chrome versions that still run the PNA preflight — it is harmless elsewhere,
// but it is not what unlocks a modern browser.
function applyCORS(req, res, allowedOrigins) {
  const origin = req.headers.origin
  const allowAll = allowedOrigins.includes('*')
  if (origin && (allowAll || allowedOrigins.includes(origin))) {
    res.setHeader('Access-Control-Allow-Origin', origin)
    res.setHeader('Vary', 'Origin')
  } else if (allowAll) {
    res.setHeader('Access-Control-Allow-Origin', '*')
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  if (req.headers['access-control-request-private-network'] === 'true') {
    res.setHeader('Access-Control-Allow-Private-Network', 'true')
  }
}

function json(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
  })
  res.end(payload)
}

async function readJSON(req, limitBytes = 64 * 1024) {
  const chunks = []
  let total = 0
  for await (const chunk of req) {
    total += chunk.length
    if (total > limitBytes) throw new Error('request body too large')
    chunks.push(chunk)
  }
  if (total === 0) return {}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

function isValidRGB(rgb) {
  return (
    rgb &&
    ['r', 'g', 'b'].every(k => Number.isFinite(rgb[k]) && rgb[k] >= 0 && rgb[k] <= 255)
  )
}

export function createServer({
  registry,
  lifx,
  govee,
  allowedOrigins,
  version,
  staticDir = null,
  store = null,
}) {
  const dispatch = {
    power: (device, body) => {
      const on = Boolean(body.on)
      const ok =
        device.brand === 'lifx' ? lifx.setPower(device, on) : govee.setPower(device, on)
      if (ok) registry.patch(device.id, { power: on }) // optimistic, confirmed on next poll
      return ok
    },
    brightness: (device, body) => {
      const value = clampPercent(body.value)
      const ok =
        device.brand === 'lifx'
          ? lifx.setColor(device, { brightnessPercent: value })
          : govee.setBrightness(device, value)
      if (ok) registry.patch(device.id, { brightness: value })
      return ok
    },
    color: (device, body) => {
      const kelvin = Number(body.kelvin) || 0
      if (!kelvin && !isValidRGB(body.rgb)) return { error: 'rgb must be three 0-255 values' }
      const ok =
        device.brand === 'lifx'
          ? lifx.setColor(device, { rgb: body.rgb, kelvin })
          : govee.setColor(device, { rgb: body.rgb, kelvin })
      if (ok) registry.patch(device.id, { color: body.rgb ?? device.color, kelvin: kelvin || null })
      return ok
    },
  }

  const decorate = devices => {
    if (!store) return devices
    const favorites = new Set(store.state.favorites)
    const rooms = store.listRooms()
    return devices.map(device => ({
      ...device,
      name: store.state.deviceNames[device.id] ?? device.name,
      favorite: favorites.has(device.id),
      roomID: rooms.find(r => r.lightIDs.includes(device.id))?.id ?? null,
    }))
  }

  /** Store-backed routes. Returns true when it handled the request. */
  const handleStore = async ({ req, res, path, url }) => {
    const body = req.method === 'POST' ? await readJSON(req) : {}

    if (req.method === 'GET' && path === '/rooms') {
      json(res, 200, { rooms: store.listRooms() })
      return true
    }
    if (req.method === 'POST' && path === '/rooms') {
      json(res, 200, { room: store.addRoom(body.name) })
      return true
    }

    let match = path.match(/^\/rooms\/([^/]+)$/)
    if (match && req.method === 'POST') {
      if (url.searchParams.get('delete') === '1') {
        json(res, store.removeRoom(match[1]) ? 200 : 404, { ok: true })
        return true
      }
      const room = store.updateRoom(match[1], body)
      json(res, room ? 200 : 404, room ? { room } : { error: 'unknown room' })
      return true
    }

    match = path.match(/^\/rooms\/([^/]+)\/schedules$/)
    if (match && req.method === 'POST') {
      const schedule = store.addSchedule(match[1], body)
      json(res, schedule ? 200 : 404, schedule ? { schedule } : { error: 'unknown room' })
      return true
    }

    match = path.match(/^\/rooms\/([^/]+)\/schedules\/([^/]+)$/)
    if (match && req.method === 'POST') {
      const [, roomID, scheduleID] = match
      if (url.searchParams.get('delete') === '1') {
        json(res, store.removeSchedule(roomID, scheduleID) ? 200 : 404, { ok: true })
        return true
      }
      const schedule = store.updateSchedule(roomID, scheduleID, body)
      json(res, schedule ? 200 : 404, schedule ? { schedule } : { error: 'unknown schedule' })
      return true
    }

    if (req.method === 'GET' && path === '/scenes') {
      json(res, 200, { scenes: store.listScenes() })
      return true
    }
    if (req.method === 'POST' && path === '/scenes') {
      // Capture the devices asked for, or every known device.
      const ids = Array.isArray(body.deviceIDs) ? body.deviceIDs : null
      const devices = registry.list().filter(d => (ids ? ids.includes(d.id) : true))
      if (!devices.length) {
        json(res, 400, { error: 'no devices to capture' })
        return true
      }
      json(res, 200, { scene: store.addScene(body.name, snapshot(devices)) })
      return true
    }

    match = path.match(/^\/scenes\/([^/]+)\/apply$/)
    if (match && req.method === 'POST') {
      const scene = store.listScenes().find(s => s.id === match[1])
      if (!scene) {
        json(res, 404, { error: 'unknown scene' })
        return true
      }
      const result = applyScene({ scene, registry, lifx, govee })
      json(res, 200, { ...result, devices: decorate(registry.list()) })
      return true
    }

    match = path.match(/^\/scenes\/([^/]+)$/)
    if (match && req.method === 'POST' && url.searchParams.get('delete') === '1') {
      json(res, store.removeScene(match[1]) ? 200 : 404, { ok: true })
      return true
    }

    match = path.match(/^\/devices\/(.+)\/(favorite|rename|room)$/)
    if (match && req.method === 'POST') {
      const deviceID = decodeURIComponent(match[1])
      if (!registry.get(deviceID)) {
        json(res, 404, { error: 'unknown device' })
        return true
      }
      if (match[2] === 'favorite') store.toggleFavorite(deviceID)
      if (match[2] === 'rename') store.renameDevice(deviceID, body.name)
      if (match[2] === 'room' && !store.assignLight(deviceID, body.roomID ?? null)) {
        json(res, 404, { error: 'unknown room' })
        return true
      }
      json(res, 200, { devices: decorate(registry.list()), rooms: store.listRooms() })
      return true
    }

    return false
  }

  return http.createServer(async (req, res) => {
    applyCORS(req, res, allowedOrigins)

    if (req.method === 'OPTIONS') {
      res.writeHead(204)
      res.end()
      return
    }

    const url = new URL(req.url, 'http://127.0.0.1')
    const path = url.pathname.replace(/\/+$/, '') || '/'

    try {
      // "/" is the web client when we are serving it; /health stays the probe
      // either way, and is what the client uses to recognise the bridge.
      if (req.method === 'GET' && (path === '/health' || (path === '/' && !staticDir))) {
        return json(res, 200, { ok: true, service: 'lumendesk-bridge', version })
      }

      if (req.method === 'GET' && path === '/devices') {
        return json(res, 200, { devices: decorate(registry.list()) })
      }

      // Everything the client needs for a first paint, in one round trip.
      if (req.method === 'GET' && path === '/state') {
        return json(res, 200, {
          devices: decorate(registry.list()),
          rooms: store ? store.listRooms() : [],
          scenes: store ? store.listScenes() : [],
          favorites: store ? store.state.favorites : [],
          actions: ACTIONS,
        })
      }

      if (req.method === 'POST' && path === '/discover') {
        lifx.discover()
        govee.discover()
        return json(res, 202, { ok: true })
      }

      if (req.method === 'POST' && path === '/refresh') {
        lifx.refresh()
        govee.refresh()
        return json(res, 202, { ok: true })
      }

      // /devices/<id>/<action> — ids contain colons, so split from the right.
      const match = path.match(/^\/devices\/(.+)\/(power|brightness|color)$/)
      if (req.method === 'POST' && match) {
        const [, rawID, action] = match
        const device = registry.get(decodeURIComponent(rawID))
        if (!device) return json(res, 404, { error: 'unknown device' })

        const body = await readJSON(req)
        const result = dispatch[action](device, body)
        if (result && result.error) return json(res, 400, result)
        if (!result) return json(res, 503, { error: 'device is not addressable yet' })
        return json(res, 200, { device: registry.get(device.id) })
      }

      if (store) {
        const stored = await handleStore({ req, res, path, url })
        if (stored) return undefined
      }

      // Anything that is not an API route is the web client, when the bridge
      // is serving it. API routes are matched first so a file can never
      // shadow one.
      if (staticDir && (req.method === 'GET' || req.method === 'HEAD')) {
        if (await serveStatic(staticDir, url.pathname, res)) return undefined
      }

      return json(res, 404, { error: 'not found' })
    } catch (err) {
      return json(res, 400, { error: err.message })
    }
  })
}
