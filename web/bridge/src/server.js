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

/**
 * CORS only stops a disallowed page from *reading* a response — a simple POST
 * (text/plain body, no preflight) is still delivered and still acts. So
 * state-changing requests are rejected outright unless the Origin is one we
 * allow, or the bridge's own origin when it is serving the page. A request
 * with no Origin at all is not browser-driven (curl, a script) and is allowed.
 */
function originPermitted(req, allowedOrigins) {
  const origin = req.headers.origin
  if (!origin) return true
  if (allowedOrigins.includes('*') || allowedOrigins.includes(origin)) return true
  const host = req.headers.host
  return Boolean(host) && (origin === `http://${host}` || origin === `https://${host}`)
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
  nanoleaf = null,
  allowedOrigins,
  version,
  staticDir = null,
  store = null,
}) {
  const musicBrightnessOpened = new Set()
  /** Shapes wall id -> what it showed before a browser music show claimed it. */
  const shapesBeforeMusic = new Map()
  const clientFor = device => ({ lifx, govee, nanoleaf })[device.brand] ?? null
  const dispatch = {
    power: (device, body) => {
      const on = Boolean(body.on)
      const ok = clientFor(device)?.setPower(device, on) ?? false
      if (ok) registry.patch(device.id, { power: on }) // optimistic, confirmed on next poll
      return ok
    },
    brightness: (device, body) => {
      const value = clampPercent(body.value)
      const ok =
        device.brand === 'lifx'
          ? lifx.setColor(device, { brightnessPercent: value })
          : clientFor(device)?.setBrightness(device, value) ?? false
      if (ok) registry.patch(device.id, { brightness: value })
      return ok
    },
    color: (device, body) => {
      const kelvin = Number(body.kelvin) || 0
      if (!kelvin && !isValidRGB(body.rgb)) return { error: 'rgb must be three 0-255 values' }
      const ok = clientFor(device)?.setColor(device, { rgb: body.rgb, kelvin }) ?? false
      if (ok) registry.patch(device.id, { color: body.rgb ?? device.color, kelvin: kelvin || null })
      return ok
    },
  }

  /**
   * Nanoleaf Shapes: panel-resolved commands. Each returns the HTTP status
   * and body; only paired Shapes walls with a read layout accept them.
   */
  const shapes = {
    orientation: (device, body) => {
      const degrees = Number(body.degrees)
      if (!Number.isFinite(degrees)) return [400, { error: 'degrees must be a number' }]
      return nanoleaf.setOrientation(device, degrees) ? [202, { device: registry.get(device.id) }]
        : [409, { error: 'the wall has not reported a layout yet' }]
    },
    panels: (device, body) => {
      const colors = body.colors
      if (!colors || typeof colors !== 'object' || Array.isArray(colors)) return [400, { error: 'colors must map panel IDs to rgb' }]
      for (const [key, rgb] of Object.entries(colors)) {
        if (!/^\d+$/.test(key) || !isValidRGB(rgb)) return [400, { error: `panel ${key} needs three 0-255 values` }]
      }
      return nanoleaf.displayPanels(device, colors) ? [202, { device: registry.get(device.id) }]
        : [409, { error: 'the wall has not reported a layout yet' }]
    },
    effect: (device, body) => nanoleaf.selectEffect(device, String(body.name ?? ''))
      ? [202, { device: registry.get(device.id) }] : [404, { error: 'the controller has no scene by that name' }],
    identify: (device, body) => nanoleaf.identifyPanel(device, Number(body.panelID))
      ? [202, { ok: true }] : [404, { error: 'no such light panel on this wall' }],
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

    // A mutation must not report success while the change exists only in
    // memory, so the write is awaited before the response is sent.
    const saved = async (status, payload) => {
      try {
        await store.flush()
      } catch (err) {
        return json(res, 500, { error: err.message })
      }
      return json(res, status, payload)
    }

    if (req.method === 'GET' && path === '/rooms') {
      json(res, 200, { rooms: store.listRooms() })
      return true
    }
    if (req.method === 'POST' && path === '/rooms') {
      await saved(200, { room: store.addRoom(body.name) })
      return true
    }

    let match = path.match(/^\/rooms\/([^/]+)$/)
    if (match && req.method === 'POST') {
      if (url.searchParams.get('delete') === '1') {
        await saved(store.removeRoom(match[1]) ? 200 : 404, { ok: true })
        return true
      }
      const room = store.updateRoom(match[1], body)
      await saved(room ? 200 : 404, room ? { room } : { error: 'unknown room' })
      return true
    }

    match = path.match(/^\/rooms\/([^/]+)\/schedules$/)
    if (match && req.method === 'POST') {
      const schedule = store.addSchedule(match[1], body)
      await saved(schedule ? 200 : 404, schedule ? { schedule } : { error: 'unknown room' })
      return true
    }

    match = path.match(/^\/rooms\/([^/]+)\/schedules\/([^/]+)$/)
    if (match && req.method === 'POST') {
      const [, roomID, scheduleID] = match
      if (url.searchParams.get('delete') === '1') {
        await saved(store.removeSchedule(roomID, scheduleID) ? 200 : 404, { ok: true })
        return true
      }
      const schedule = store.updateSchedule(roomID, scheduleID, body)
      await saved(schedule ? 200 : 404, schedule ? { schedule } : { error: 'unknown schedule' })
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
      await saved(200, { scene: store.addScene(body.name, snapshot(devices)) })
      return true
    }

    match = path.match(/^\/scenes\/([^/]+)\/apply$/)
    if (match && req.method === 'POST') {
      const scene = store.listScenes().find(s => s.id === match[1])
      if (!scene) {
        json(res, 404, { error: 'unknown scene' })
        return true
      }
      const result = applyScene({ scene, registry, lifx, govee, nanoleaf })
      json(res, 200, { ...result, devices: decorate(registry.list()) })
      return true
    }

    match = path.match(/^\/scenes\/([^/]+)$/)
    if (match && req.method === 'POST' && url.searchParams.get('delete') === '1') {
      await saved(store.removeScene(match[1]) ? 200 : 404, { ok: true })
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
      await saved(200, { devices: decorate(registry.list()), rooms: store.listRooms() })
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

    if (req.method !== 'GET' && req.method !== 'HEAD' && !originPermitted(req, allowedOrigins)) {
      return json(res, 403, { error: 'origin not allowed' })
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
        // Awaited so the caller gets the probe reports back. "Nothing found"
        // and "nothing we sent ever left the machine" are different problems,
        // and the client can only tell them apart if it is told.
        const [lifxProbe, goveeProbe, nanoleafProbe] = await Promise.all([
          lifx.discover().catch(err => ({ error: err.message })),
          govee.discover().catch(err => ({ error: err.message })),
          nanoleaf ? nanoleaf.discover().catch(err => ({ error: err.message })) : null,
        ])
        return json(res, 200, { ok: true, probes: { lifx: lifxProbe, govee: goveeProbe, nanoleaf: nanoleafProbe } })
      }

      if (req.method === 'POST' && path === '/refresh') {
        lifx.refresh()
        govee.refresh()
        nanoleaf?.refresh()
        return json(res, 202, { ok: true })
      }

      // Pairing needs the controller's window open (power button held 5–7 s).
      // The credential it returns stays in the bridge; the page never sees it.
      if (req.method === 'POST' && path === '/nanoleaf/pair') {
        if (!nanoleaf) return json(res, 404, { error: 'not found' })
        const body = await readJSON(req)
        try {
          const device = await nanoleaf.pair({ host: body.host, port: body.port ?? 16021 })
          return json(res, 200, { device })
        } catch (err) {
          const status = err.code === 'invalidAddress' ? 400 : err.code === 'pairingWindowClosed' ? 403 : 502
          return json(res, status, { error: err.message })
        }
      }

      const shapesMatch = path.match(/^\/devices\/(.+)\/(orientation|panels|effect|identify|forget)$/)
      if (req.method === 'POST' && shapesMatch && nanoleaf) {
        const device = registry.get(decodeURIComponent(shapesMatch[1]))
        if (!device || device.brand !== 'nanoleaf') return json(res, 404, { error: 'unknown Shapes wall' })
        const body = await readJSON(req)
        if (shapesMatch[2] === 'forget') {
          const forgotten = await nanoleaf.forget(device)
          if (forgotten) registry.devices.delete(device.id)
          return json(res, forgotten ? 200 : 404, forgotten ? { ok: true } : { error: 'not paired' })
        }
        if (shapesMatch[2] !== 'identify') {
          registry.claimControl(device.id)
          musicBrightnessOpened.delete(device.id)
        }
        const [status, payload] = shapes[shapesMatch[2]](device, body)
        return json(res, status, payload)
      }

      // /devices/<id>/<action> — ids contain colons, so split from the right.
      const match = path.match(/^\/devices\/(.+)\/(power|brightness|color)$/)
      if (req.method === 'POST' && match) {
        const [, rawID, action] = match
        const device = registry.get(decodeURIComponent(rawID))
        if (!device) return json(res, 404, { error: 'unknown device' })

        const body = await readJSON(req)
        registry.claimControl(device.id)
        musicBrightnessOpened.delete(device.id)
        const result = dispatch[action](device, body)
        if (result && result.error) return json(res, 400, result)
        if (!result) return json(res, 503, { error: 'device is not addressable yet' })
        return json(res, 200, { device: registry.get(device.id) })
      }

      // Music Mode frames are computed in the browser. One solid colour per
      // fixture — RGBIC razer is not spoken here, so a strip follows as a wash
      // until that encoder is ported in lockstep with ProtocolTests.
      if (req.method === 'POST' && path === '/music/frame') {
        const body = await readJSON(req)
        const restoreShapes = (device, before, level) => {
          if (level !== undefined) nanoleaf.setBrightness(device, level * 100)
          if (before.output === 'design' && before.design) return nanoleaf.displayPanels(device, before.design)
          if (before.output === 'effect' && before.effect) return nanoleaf.selectEffect(device, before.effect)
          if (before.output === 'white' && before.kelvin) return nanoleaf.setColor(device, { kelvin: before.kelvin })
          return null
        }
        const states = Array.isArray(body.states) ? body.states : []
        let applied = 0
        const seen = new Set()
        for (const state of states) {
          const id = state && state.fixtureID
          if (!id || seen.has(id)) continue
          seen.add(id)
          const device = registry.get(id)
          if (!device) continue
          const rgb = state.rgb
          if (!isValidRGB(rgb)) continue
          if (state.owner) {
            if (state.controlRevision !== device.controlRevision) continue
            if (device.musicOwner && device.musicOwner !== state.owner && performance.now()-(device.musicFrameAt ?? 0)<2000) continue
            if ((state.restoring || state.release) && device.musicOwner !== state.owner) continue
            if (state.release) {
              registry.patch(id,{musicOwner:null});musicBrightnessOpened.delete(id);shapesBeforeMusic.delete(id);continue
            }
            if (!device.musicOwner || device.musicOwner !== state.owner) musicBrightnessOpened.delete(id)
            // A show starting on a Shapes wall remembers what the wall showed,
            // so a restore brings back the design or scene, not just a colour.
            if (device.brand === 'nanoleaf' && !state.restoring && device.musicOwner !== state.owner) {
              const shapes = device.shapes ?? {}
              shapesBeforeMusic.set(id, { owner: state.owner, output: shapes.output, design: shapes.design,
                effect: shapes.effect, kelvin: device.kelvin })
            }
            registry.patch(id,{musicOwner:state.restoring?null:state.owner,musicFrameAt:performance.now()})
          }
          // RGB is chroma; brightness is independent (legacy RGB-only callers
          // still retain the device's current brightness).
          const level = Number.isFinite(state.brightness) ? Math.max(0,Math.min(1,state.brightness)) : undefined
          const restoring = state.restoring === true
          let payload = rgb
          if (device.brand === 'govee' && level !== undefined) {
            if (restoring) {
              govee.setBrightness(device, level * 100)
              musicBrightnessOpened.delete(device.id)
            } else {
              if (!musicBrightnessOpened.has(device.id)) {
                govee.setBrightness(device,100)
                musicBrightnessOpened.add(device.id)
              }
              payload = Object.fromEntries(Object.entries(rgb).map(([k,v])=>[k,Math.round(v*level)]))
            }
          }
          // A Shapes wall follows the show as one colour here, paced by its
          // client; its per-panel stream is the native app's.
          const before = device.brand === 'nanoleaf' && restoring && state.owner ? shapesBeforeMusic.get(id) : undefined
          if (device.brand === 'nanoleaf' && restoring) shapesBeforeMusic.delete(id)
          const restoredShapes = before?.owner === state.owner && nanoleaf ? restoreShapes(device, before, level) : null
          const ok = restoredShapes !== null
            ? restoredShapes
            : device.brand === 'lifx'
              ? lifx.setColor(device, {rgb,brightnessPercent:level === undefined ? undefined : level*100,
                  durationMS:Number.isFinite(state.transitionDuration)?Math.max(0,Math.min(500,state.transitionDuration*1000)):90})
              : device.brand === 'nanoleaf'
                ? Boolean(nanoleaf?.setColor(device, {rgb,brightnessPercent:level === undefined ? undefined : level*100,transient:!restoring}))
                : govee.setColor(device, {rgb:payload})
          if (ok) {
            // Colour only: this path never sends a power command, so it must
            // not record a power state it did not set. The device's own status
            // reply is what says whether the light is lit.
            registry.patch(device.id, { color: payload, ...(level !== undefined ? {brightness: device.brand === 'lifx' || restoring ? level*100 : 100} : {}) })
            applied += 1
          }
        }
        return json(res, 200, { ok: true, applied, stage: 'accepted-for-local-dispatch' })
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
