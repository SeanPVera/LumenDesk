import http from 'node:http'
import { clampPercent } from './color.js'

// A page served from https://<user>.github.io may call this bridge because
// 127.0.0.1 is a "potentially trustworthy" origin, so it is exempt from mixed
// content blocking. Chrome additionally gates public -> private requests behind
// Private Network Access: the preflight carries
// Access-Control-Request-Private-Network and only proceeds if we answer
// Access-Control-Allow-Private-Network: true.
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

export function createServer({ registry, lifx, govee, allowedOrigins, version }) {
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
      if (req.method === 'GET' && (path === '/' || path === '/health')) {
        return json(res, 200, { ok: true, service: 'lumendesk-bridge', version })
      }

      if (req.method === 'GET' && path === '/devices') {
        return json(res, 200, { devices: registry.list() })
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

      return json(res, 404, { error: 'not found' })
    } catch (err) {
      return json(res, 400, { error: err.message })
    }
  })
}
