import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import * as nanoleaf from './nanoleaf.js'
import { clampPercent, hsvToRgb, rgbToHsv } from './color.js'

// Nanoleaf Shapes over the documented local HTTP API, ported from
// LumenDesk/Services/Nanoleaf/NanoleafClient.swift. Unlike LIFX and Govee
// there is no UDP discovery to join: a controller is paired once by address
// (hold its power button 5–7 s first), and the credential it returns is kept
// in its own file, readable only by this user, and never sent to a browser.
//
// Every controller has one ordered lane with a single coalesced successor, so
// a slow controller cannot pile up stale commands: a newer colour, scene or
// panel layout replaces a queued older one.

const DEFAULT_CREDENTIALS = path.join(os.homedir(), '.lumendesk', 'nanoleaf-pairings.json')
const REQUEST_TIMEOUT_MS = 2000
/** Music colours reach a wall at most this often, newest first: the ceiling
 *  MusicLightingRenderer gives whole-controller Nanoleaf updates. */
export const MUSIC_INTERVAL_MS = 200

export class NanoleafError extends Error {
  constructor(code, message) {
    super(message)
    this.code = code
  }
}

const ERRORS = {
  pairingWindowClosed: 'Hold the Shapes power button for 5–7 seconds until its LED flashes, then pair within 30 seconds.',
  pairingRequired: 'Nanoleaf access expired. Pair this controller again.',
  unavailable: 'Cannot reach the Nanoleaf controller. Check its power and your local network connection.',
  invalidResponse: 'The Nanoleaf controller returned an unreadable response.',
  unsupportedModel: 'This integration supports Nanoleaf Shapes (NL42).',
  invalidAddress: 'Enter the controller’s IP address or local hostname and a port from 1 to 65535.',
}

const fail = code => new NanoleafError(code, ERRORS[code])

/** An address or hostname only: never a URL, credentials or a path. */
export function validatedEndpoint(host, port = nanoleaf.API_PORT) {
  const trimmed = String(host ?? '').trim()
  const number = Number(port)
  const ipv6 = (trimmed.match(/:/g) ?? []).length > 1
  if (!trimmed || !Number.isInteger(number) || number < 1 || number > 65535 ||
      /[/?#@\\\s]/.test(trimmed) || (trimmed.includes(':') && !ipv6)) {
    throw fail('invalidAddress')
  }
  return { host: trimmed, port: number }
}

const urlFor = (endpoint, pathname) => {
  const host = endpoint.host.includes(':') && !endpoint.host.startsWith('[') ? `[${endpoint.host}]` : endpoint.host
  return `http://${host}:${endpoint.port}${pathname}`
}

export class NanoleafClient {
  constructor({ registry, log = () => {}, credentialsFile = DEFAULT_CREDENTIALS, fetchImpl = globalThis.fetch,
    now = () => performance.now(), sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) }) {
    this.registry = registry
    this.log = log
    this.credentialsFile = credentialsFile
    this.fetch = fetchImpl
    this.now = now
    this.sleep = sleep
    /** serial -> { serial, name, host, port, token } */
    this.pairings = new Map()
    /** serial -> { running, pending } */
    this.lanes = new Map()
    /** serial -> panel colours LumenDesk last displayed, while it still owns the wall. */
    this.designs = new Map()
  }

  async start() {
    try {
      const raw = await fsp.readFile(this.credentialsFile, 'utf8')
      for (const entry of JSON.parse(raw)) {
        if (entry && typeof entry.serial === 'string' && typeof entry.token === 'string' && entry.host) {
          this.pairings.set(entry.serial, entry)
        }
      }
    } catch (err) {
      if (err.code !== 'ENOENT') this.log(`Nanoleaf pairings could not be read: ${err.message}`)
    }
    this.refresh()
  }

  stop() {
    this.lanes.clear()
  }

  async #save() {
    await fsp.mkdir(path.dirname(this.credentialsFile), { recursive: true, mode: 0o700 })
    const temporary = `${this.credentialsFile}.${process.pid}.tmp`
    await fsp.writeFile(temporary, JSON.stringify([...this.pairings.values()], null, 2), { mode: 0o600 })
    await fsp.rename(temporary, this.credentialsFile)
    await fsp.chmod(this.credentialsFile, 0o600).catch(() => {})
  }

  async #request(endpoint, pathname, { method = 'GET', body, pairing = false } = {}) {
    let response
    try {
      response = await this.fetch(urlFor(endpoint, pathname), {
        method,
        headers: body ? { 'Content-Type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined,
        redirect: 'manual',
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      })
    } catch {
      // The raw error can carry the URL, and the URL carries the credential.
      throw fail('unavailable')
    }
    if (response.status === 401 || response.status === 403) throw fail(pairing ? 'pairingWindowClosed' : 'pairingRequired')
    if (response.status < 200 || response.status >= 300) {
      throw new NanoleafError('http', `The Nanoleaf controller rejected the request (HTTP ${response.status}).`)
    }
    const text = await response.text()
    if (!text) return null
    try {
      return JSON.parse(text)
    } catch {
      throw fail('invalidResponse')
    }
  }

  /** Pairs with a controller whose pairing window is open, by address. */
  async pair({ host, port }) {
    const endpoint = validatedEndpoint(host, port)
    const created = await this.#request(endpoint, '/api/v1/new', { method: 'POST', pairing: true })
    const token = created?.auth_token
    if (typeof token !== 'string' || !/^[A-Za-z0-9]+$/.test(token)) throw fail('invalidResponse')
    const info = await this.#request(endpoint, `/api/v1/${token}`)
    if (!info || typeof info.serialNo !== 'string' || !info.serialNo) throw fail('invalidResponse')
    if (String(info.model).toUpperCase() !== 'NL42') throw fail('unsupportedModel')
    const pairing = { serial: info.serialNo, name: String(info.name ?? 'Nanoleaf Shapes'), ...endpoint, token }
    this.pairings.set(pairing.serial, pairing)
    await this.#save()
    this.#absorb(pairing, info)
    return this.registry.get(`nanoleaf:${pairing.serial}`)
  }

  /** Forgets a controller's credential. Nothing is sent to the controller. */
  async forget(device) {
    const serial = this.#serial(device)
    if (!serial || !this.pairings.delete(serial)) return false
    this.lanes.delete(serial)
    this.designs.delete(serial)
    await this.#save()
    return true
  }

  /** Paired controllers are reached by address; a pass is a fresh reading. */
  discover() {
    this.refresh()
    return Promise.resolve({ sent: this.pairings.size, paired: this.pairings.size })
  }

  refresh() {
    for (const serial of this.pairings.keys()) this.#queue(serial, { refresh: true })
  }

  // MARK: Commands, same shape as the LIFX and Govee clients

  setPower(device, on) {
    return this.#queue(this.#serial(device), { state: { on: { value: Boolean(on) } } })
  }

  setBrightness(device, percent) {
    return this.#queue(this.#serial(device), { state: { brightness: { value: clampPercent(percent) } } })
  }

  /** Colour temperature when `kelvin` is set, otherwise hue and saturation. */
  setColor(device, { rgb, kelvin, brightnessPercent, transient = false }) {
    const serial = this.#serial(device)
    const state = {}
    if (kelvin) {
      state.ct = { value: Math.max(1200, Math.min(6500, Math.round(kelvin))) }
    } else if (rgb) {
      const { h, s } = rgbToHsv(rgb)
      state.hue = { value: Math.min(359, Math.round(h)) }
      state.sat = { value: Math.round(s * 100) }
    }
    if (brightnessPercent !== undefined) state.brightness = { value: clampPercent(brightnessPercent) }
    if (!Object.keys(state).length) return false
    this.designs.delete(serial)
    // Music frames are transient: no read-back after each one.
    return this.#queue(serial, { state, output: null, clearsOutput: 'hue' in state || 'ct' in state, transient })
  }

  selectEffect(device, name) {
    const serial = this.#serial(device)
    if (!this.registry.get(device.id)?.shapes?.effects?.includes(name)) return false
    this.designs.delete(serial)
    return this.#queue(serial, { output: { effect: name } })
  }

  /** Writes the global orientation; success is what reads back, not the 204. */
  setOrientation(device, degrees) {
    const serial = this.#serial(device)
    const current = this.registry.get(device.id)?.shapes
    if (!current?.layout) return false
    const value = nanoleaf.writableOrientation(degrees, current.orientationReport)
    this.registry.patch(device.id, { shapes: { ...current, orientationPending: value } })
    return this.#queue(serial, { orientation: value })
  }

  /** Shows per-panel colours as LumenDesk's own static layout. */
  displayPanels(device, colors) {
    const serial = this.#serial(device)
    const layout = this.registry.get(device.id)?.shapes?.layout
    if (!layout) return false
    const frames = nanoleaf.designFrames(layout, colors, 3)
    this.designs.set(serial, Object.fromEntries(frames.map(f => [f.panelID, { r: f.r, g: f.g, b: f.b }])))
    return this.#queue(serial, { output: { frames } })
  }

  /** A gentle, temporary cue: `displayTemp` restores the wall by itself. */
  identifyPanel(device, panelID) {
    const serial = this.#serial(device)
    const layout = this.registry.get(device.id)?.shapes?.layout
    if (!layout || !nanoleaf.paintablePanels(layout).some(p => p.panelID === panelID)) return false
    return this.#queue(serial, { identify: panelID })
  }

  // MARK: Lane

  #serial(device) {
    const serial = device?.id?.startsWith('nanoleaf:') ? device.id.slice('nanoleaf:'.length) : null
    return serial && this.pairings.has(serial) ? serial : null
  }

  #queue(serial, command) {
    if (!serial || !this.pairings.has(serial)) return false
    let lane = this.lanes.get(serial)
    if (!lane) {
      lane = { running: false, pending: null, lastTransient: -Infinity }
      this.lanes.set(serial, lane)
    }
    const next = lane.pending ?? { state: {}, output: undefined, orientation: undefined, identify: undefined, refresh: false }
    if (command.clearsOutput) next.output = undefined
    if (command.state) {
      if ('hue' in command.state) delete next.state.ct
      if ('ct' in command.state) { delete next.state.hue; delete next.state.sat }
      Object.assign(next.state, command.state)
    }
    if (command.output) {
      // A scene or panel layout replaces a colour still queued, and the newest wins.
      delete next.state.hue
      delete next.state.sat
      delete next.state.ct
      next.output = command.output
    }
    if (command.orientation !== undefined) next.orientation = command.orientation
    if (command.identify !== undefined) next.identify = command.identify
    // Paced only while everything merged into it is a music frame.
    next.transient = (next.transient ?? true) && Boolean(command.transient)
    next.refresh = next.refresh || Boolean(command.refresh) ||
      (!command.transient && Boolean(command.state || command.output || command.orientation !== undefined))
    lane.pending = next
    this.#drain(serial, lane)
    return true
  }

  async #drain(serial, lane) {
    if (lane.running) return
    lane.running = true
    try {
      while (lane.pending && this.lanes.get(serial) === lane) {
        if (lane.pending.transient) {
          const wait = lane.lastTransient + MUSIC_INTERVAL_MS - this.now()
          // Newer frames replace the queued one while this waits.
          if (wait > 0) { await this.sleep(wait); continue }
          lane.lastTransient = this.now()
        }
        const command = lane.pending
        lane.pending = null
        const pairing = this.pairings.get(serial)
        if (!pairing) break
        await this.#run(pairing, command).catch(err => this.#failed(pairing, err))
      }
    } finally {
      lane.running = false
    }
  }

  async #run(pairing, command) {
    const base = `/api/v1/${pairing.token}`
    if (Object.keys(command.state).length) {
      await this.#request(pairing, `${base}/state`, { method: 'PUT', body: command.state })
    }
    if (command.output?.effect) {
      await this.#request(pairing, `${base}/effects`, { method: 'PUT', body: nanoleaf.selectBody(command.output.effect) })
    } else if (command.output?.frames) {
      await this.#request(pairing, `${base}/effects`, { method: 'PUT', body: nanoleaf.displayStaticBody(command.output.frames) })
    }
    if (command.orientation !== undefined) {
      await this.#request(pairing, `${base}/panelLayout`, { method: 'PUT', body: nanoleaf.orientationBody(command.orientation) })
    }
    if (command.identify !== undefined) {
      const layout = this.registry.get(`nanoleaf:${pairing.serial}`)?.shapes?.layout
      if (layout) await this.#request(pairing, `${base}/effects`, { method: 'PUT', body: identifyBody(command.identify, layout) })
    }
    if (command.refresh) {
      const info = await this.#request(pairing, base)
      this.#absorb(pairing, info)
    }
  }

  #failed(pairing, err) {
    const id = `nanoleaf:${pairing.serial}`
    const device = this.registry.get(id)
    const message = err instanceof NanoleafError ? err.message : ERRORS.unavailable
    if (device) {
      this.registry.patch(id, {
        needsPairing: err?.code === 'pairingRequired',
        shapes: device.shapes ? { ...device.shapes, lastFailure: message, orientationPending: null } : device.shapes,
      })
    }
    this.log(`Nanoleaf ${pairing.name}: ${message}`)
  }

  /** Takes in a controller reading. The layout is parsed strictly; a damaged
   *  one keeps the last layout that could be trusted. */
  #absorb(pairing, info) {
    if (!info || info.serialNo !== pairing.serial) throw fail('invalidResponse')
    const id = `nanoleaf:${pairing.serial}`
    const previous = this.registry.get(id)?.shapes
    const state = info.state ?? {}
    const effects = Array.isArray(info.effects?.effectsList) ? info.effects.effectsList.map(String) : []
    const select = String(info.effects?.select ?? '')
    let layout = previous?.layout ?? null
    let orientationReport = previous?.orientationReport ?? { kind: 'notReported' }
    let problem = null
    try {
      const parsed = nanoleaf.parseTopology(info)
      layout = parsed.layout
      orientationReport = parsed.orientation
    } catch (err) {
      problem = err instanceof nanoleaf.TopologyProblem ? err.message : ERRORS.invalidResponse
    }
    const on = Boolean(state.on?.value)
    const colorMode = String(state.colorMode ?? '')
    const design = this.designs.get(pairing.serial) ?? null
    let output
    if (!on) output = 'off'
    else if (colorMode === 'hs') output = 'solid'
    else if (colorMode === 'ct') output = 'white'
    else if (select === '*Static*') output = design ? 'design' : 'external'
    else if (effects.includes(select)) output = 'effect'
    else output = 'external'
    // Something else is showing now: the design no longer counts as shown.
    // Unless a newer output is still queued: the lane is ordered, so this
    // reading was taken before that write and says nothing about it.
    const newerOutputQueued = Boolean(this.lanes.get(pairing.serial)?.pending?.output)
    if (on && output !== 'design' && output !== 'off' && !newerOutputQueued) this.designs.delete(pairing.serial)
    const hue = Number(state.hue?.value) || 0
    const sat = Number(state.sat?.value) || 0
    this.registry.upsert(id, {
      brand: 'nanoleaf',
      name: String(info.name ?? pairing.name),
      ip: pairing.host,
      model: 'NL42',
      power: on,
      brightness: clampPercent(state.brightness?.value),
      color: hsvToRgb({ h: Math.min(359, hue), s: Math.min(100, sat) / 100, v: 1 }),
      kelvin: colorMode === 'ct' ? Number(state.ct?.value) || null : null,
      needsPairing: false,
      shapes: {
        layout,
        geometry: layout ? nanoleaf.drawingGeometry(layout) : null,
        orientation: nanoleaf.orientationDegrees(orientationReport),
        orientationReport,
        orientationPending: null,
        output,
        effect: output === 'effect' ? select : null,
        effects,
        design: output === 'design' || output === 'off' ? design : null,
        firmware: typeof info.firmwareVersion === 'string' ? info.firmwareVersion : previous?.firmware ?? null,
        problem,
        lastFailure: null,
      },
    })
  }
}

/** Same cue as NanoleafCommand.identifyPanel: one panel breathes, the rest hold dim. */
export function identifyBody(panelID, layout, seconds = 4) {
  const parts = [String(nanoleaf.paintablePanels(layout).length)]
  for (const panel of nanoleaf.paintablePanels(layout)) {
    parts.push(panel.panelID === panelID ? `${panel.panelID} 2 255 255 255 0 5 40 40 40 0 5` : `${panel.panelID} 1 20 20 20 0 3`)
  }
  return {
    write: {
      command: 'displayTemp',
      duration: Math.max(1, Math.min(30, seconds)),
      version: '2.0',
      animType: 'custom',
      animData: parts.join(' '),
      loop: true,
      palette: [],
      colorType: 'HSB',
    },
  }
}

export function credentialFileMode(file) {
  try {
    return fs.statSync(file).mode & 0o777
  } catch {
    return null
  }
}
