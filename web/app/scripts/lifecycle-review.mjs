import { chromium, expect } from '@playwright/test'
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { drawingGeometry, parseTopology } from '../../bridge/src/nanoleaf.js'

const deferred = () => {
  let resolve
  const promise = new Promise(done => { resolve = done })
  return { promise, resolve }
}

function initialState() {
  const topology = parseTopology({ panelLayout: {
    globalOrientation: { value: 0, max: 360, min: 0 },
    layout: { positionData: [
      { panelId: 11, x: 0, y: 0, o: 0, shapeType: 7 },
      { panelId: 12, x: 100.5, y: 58.02, o: 0, shapeType: 7 },
    ] },
  } })
  return {
    devices: [
      { id: 'lifx:test', name: 'Test lamp', brand: 'lifx', reachable: true, power: true,
        brightness: 65, color: { r: 255, g: 190, b: 100 }, kelvin: 3000, controlRevision: 0 },
      { id: 'nanoleaf:TEST', name: 'Test wall', brand: 'nanoleaf', reachable: true, power: true,
        brightness: 70, color: { r: 255, g: 120, b: 40 }, kelvin: null, controlRevision: 0,
        shapes: { family: 'shapes', geometry: drawingGeometry(topology.layout), orientation: 0,
          orientationPending: null, output: 'design', effect: null, effects: [],
          design: { 11: { r: 255, g: 120, b: 40 }, 12: { r: 0, g: 255, b: 255 } },
          firmware: 'test', problem: null, lastFailure: null } },
    ],
    rooms: [], scenes: [], favorites: [],
  }
}

async function mockApp(browser, origin, { crossOrigin = false, prepareState } = {}) {
  const context = await browser.newContext()
  await context.addInitScript(() => window.localStorage.setItem('LumenDesk.roomSetupDismissed.v1', 'true'))
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.clock.install()
  const state = initialState()
  prepareState?.(state)
  const commands = []
  const handlers = { paint: null, poll: null, restore: null }
  await context.route('**/*', async route => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/health') {
      if (crossOrigin && url.origin === origin) return route.fulfill({ status: 404, json: {} })
      return route.fulfill({ json: { ok: true, service: 'lumendesk-bridge' } })
    }
    if (path === '/state') {
      if (handlers.poll) return handlers.poll(route, url)
      return route.fulfill({ json: state })
    }
    if (route.request().method() === 'POST') {
      const data = route.request().postDataJSON()
      commands.push({ path, data })
      if (path.endsWith('/panels')) {
        if (handlers.paint) return handlers.paint(route, data)
        const wall = state.devices[1]
        wall.shapes.design = data.colors
        return route.fulfill({ json: { device: wall } })
      }
      if (path === '/music/frame') {
        if (data.states.some(state => state.restoring) && handlers.restore) await handlers.restore(route, data)
        for (const output of data.states) {
          const device = state.devices.find(device => device.id === output.fixtureID)
          if (device) Object.assign(device, { color: output.rgb, brightness: output.brightness * 100 })
        }
        return route.fulfill({ json: { ok: true, applied: data.states.length } })
      }
    }
    // Tests never reach a physical bridge, a device, or an external service.
    if (url.origin === origin) return route.continue()
    return route.abort()
  })
  await page.goto(origin)
  await page.getByRole('heading', { name: 'Fixtures', exact: true }).waitFor()
  return { context, page, state, commands, handlers, errors }
}

const frames = app => app.commands.filter(command => command.path === '/music/frame')
const restores = app => frames(app).filter(command => command.data.states.some(state => state.restoring))
const baseline = state => state.devices.map(device => ({
  fixtureID: device.id, rgb: structuredClone(device.color), brightness: device.brightness / 100,
}))

async function startDemo(app) {
  await app.page.getByRole('button', { name: 'Demo groove', exact: true }).click()
  await app.page.getByRole('button', { name: /^(Start|Restart)$/ }).click()
  await app.page.getByText(/Running · Demo groove/).waitFor()
  const before = frames(app).length
  await app.page.clock.runFor(300)
  await expect.poll(() => frames(app).length).toBeGreaterThan(before)
}

async function pendingMidi(page) {
  await page.evaluate(() => {
    navigator.requestMIDIAccess = () => new Promise((_, reject) => { window.rejectMidi = reject })
  })
  await page.getByRole('button', { name: 'MIDI clock', exact: true }).click()
  await page.getByRole('button', { name: /^(Start|Restart)$/ }).click()
  await page.waitForFunction(() => typeof window.rejectMidi === 'function')
}

async function reviewPainting(browser, origin) {
  const app = await mockApp(browser, origin)
  try {
    const { page, handlers, commands } = app
    await page.getByRole('button', { name: /^Test wall, / }).click()
    await page.getByRole('button', { name: 'Paint from what the wall shows' }).click()
    await page.getByLabel('Hex', { exact: true }).fill('#304050')
    await page.getByRole('button', { name: 'Set', exact: true }).click()
    handlers.paint = route => route.fulfill({ status: 409, json: { error: 'Controller rejected painting' } })
    await page.getByRole('button', { name: 'Apply to wall' }).click()
    await page.getByText('Controller rejected painting', { exact: true }).waitFor()
    await expect(page.getByRole('button', { name: 'Apply to wall' })).toBeEnabled()
    await expect(page.getByRole('button', { name: 'Undo', exact: true })).toBeEnabled()
    await expect(page.locator('.shapes-panel polygon').first()).toHaveAttribute('fill', '#304050')
    const rejected = structuredClone(commands.find(command => command.path.endsWith('/panels')).data)
    await page.getByRole('button', { name: 'Undo', exact: true }).click()
    await expect(page.locator('.shapes-panel polygon').first()).not.toHaveAttribute('fill', '#304050')
    await page.getByRole('button', { name: 'Redo', exact: true }).click()
    await expect(page.locator('.shapes-panel polygon').first()).toHaveAttribute('fill', '#304050')
    handlers.paint = null
    await page.getByRole('button', { name: 'Apply to wall' }).click()
    await page.getByRole('button', { name: 'Paint from what the wall shows' }).waitFor()
    assert.deepEqual(commands.filter(command => command.path.endsWith('/panels')).at(-1).data, rejected)

    // A successful write must also leave any edits made during its request.
    await page.getByRole('button', { name: 'Paint from what the wall shows' }).click()
    const gate = deferred()
    handlers.paint = async (route, data) => {
      await gate.promise
      app.state.devices[1].shapes.design = data.colors
      await route.fulfill({ json: { device: app.state.devices[1] } })
    }
    await page.getByRole('button', { name: 'Apply to wall' }).click()
    await expect(page.getByRole('button', { name: 'Applying…', exact: true })).toBeDisabled()
    await page.getByLabel('Hex', { exact: true }).fill('#708090')
    await page.getByRole('button', { name: 'Set', exact: true }).click()
    gate.resolve()
    await expect(page.getByRole('button', { name: 'Apply to wall' })).toBeEnabled()
    await expect(page.locator('.shapes-panel polygon').first()).toHaveAttribute('fill', '#708090')
    assert.deepEqual(app.errors, [])
  } finally { await app.context.close() }
}

async function reviewMusic(browser, origin) {
  const app = await mockApp(browser, origin)
  try {
    const { page, handlers } = app
    const previous = baseline(app.state)
    await page.getByRole('button', { name: 'Music', exact: true }).click()
    await startDemo(app)
    await page.clock.runFor(1500) // React has now polled the show's colors.
    await page.evaluate(() => { navigator.requestMIDIAccess = () => Promise.reject(new Error('MIDI denied')) })
    const gate = deferred(), restoring = deferred()
    handlers.restore = async () => { restoring.resolve(); await gate.promise }
    await page.getByRole('button', { name: 'MIDI clock', exact: true }).click()
    assert.equal(restores(app).length, 0, 'selecting a source must not stop or restore the running show')
    await page.getByRole('button', { name: 'Restart', exact: true }).click()
    await page.getByText('MIDI denied', { exact: true }).waitFor()
    await restoring.promise
    assert.deepEqual(restores(app)[0].data.states.map(({ fixtureID, rgb, brightness }) => ({ fixtureID, rgb, brightness })), previous)
    const atRestore = frames(app).length
    await page.getByRole('button', { name: 'Demo groove', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Start', exact: true })).toBeDisabled()
    await page.clock.runFor(500)
    assert.equal(frames(app).length, atRestore, 'starting a new show waits for failed-source restoration')
    gate.resolve()
    await page.getByRole('button', { name: 'Start', exact: true }).click()
    await page.getByText(/Running · Demo groove/).waitFor()
    await page.clock.runFor(300)
    await expect.poll(() => frames(app).length).toBeGreaterThan(atRestore)
    handlers.restore = null

    // Stop invalidates a permission request without waiting for its reply.
    await pendingMidi(page)
    const beforeStop = restores(app).length
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect.poll(() => restores(app).length).toBe(beforeStop + 1)
    assert.deepEqual(restores(app).at(-1).data.states.map(({ fixtureID, rgb, brightness }) => ({ fixtureID, rgb, brightness })), previous,
      'a restart queued during restoration must not capture stale show colors')
    await startDemo(app)
    await page.evaluate(() => { window.rejectMidi(new Error('Late MIDI rejection')) })
    await page.clock.runFor(300)
    await expect(page.getByRole('button', { name: 'Stop', exact: true })).toBeEnabled()
    assert.equal(restores(app).length, beforeStop + 1, 'the cancelled source cannot restore over a newer show')

    // Stop cancels an unresolved source before an explicit newer Start. Its
    // late failure cannot replace the fresh show's starting-light snapshot.
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect.poll(() => restores(app).length).toBe(beforeStop + 2)
    await page.clock.runFor(1500)
    await startDemo(app)
    const currentBaseline = restores(app).at(-1).data.states.map(({ fixtureID, rgb, brightness }) => ({ fixtureID, rgb, brightness }))
    await page.clock.runFor(1500) // Poll the show output before the source change.
    await pendingMidi(page)
    await page.getByRole('button', { name: 'Demo groove', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Starting…', exact: true })).toBeDisabled()
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect.poll(() => restores(app).length).toBe(beforeStop + 3)
    await startDemo(app)
    await page.evaluate(() => { window.rejectMidi(new Error('Superseded MIDI rejection')) })
    await page.getByText(/Running · Demo groove/).waitFor()
    await page.clock.runFor(300)
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect.poll(() => restores(app).length).toBe(beforeStop + 4)
    assert.deepEqual(restores(app).at(-1).data.states.map(({ fixtureID, rgb, brightness }) => ({ fixtureID, rgb, brightness })), currentBaseline)
    assert.deepEqual(app.errors, [])
  } finally { await app.context.close() }
}

async function reviewPolling(browser, origin) {
  const app = await mockApp(browser, origin)
  try {
    const { page, handlers } = app
    await page.getByRole('button', { name: 'Music', exact: true }).click()
    await startDemo(app)
    for (const outcome of ['failure', 'success']) {
      const gate = deferred(), started = deferred(), completed = deferred()
      let count = 0
      const old = initialState()
      old.devices[0].name = 'Obsolete lamp'
      handlers.poll = async route => {
        if (++count === 1) {
          started.resolve()
          await gate.promise
          if (outcome === 'failure') await route.abort('connectionrefused')
          else await route.fulfill({ json: old })
          completed.resolve()
          return
        }
        app.state.devices[0].name = 'Fresh lamp'
        return route.fulfill({ json: app.state })
      }
      await page.clock.runFor(1500)
      await started.promise
      await page.clock.runFor(1500)
      await expect.poll(() => count).toBeGreaterThan(1)
      gate.resolve()
      await completed.promise
      await page.clock.runFor(300)
      await expect(page.getByRole('button', { name: 'Stop', exact: true })).toBeEnabled()
      assert.equal(restores(app).length, 0, 'a stale poll must not stop the show')
    }
    await page.getByRole('button', { name: 'Light', exact: true }).click()
    await expect(page.getByRole('button', { name: /^Fresh lamp, / })).toBeVisible()
    handlers.poll = route => route.abort('connectionrefused')
    await page.clock.runFor(1500)
    await page.getByText(/Reconnecting automatically/).waitFor()
    await expect(page.getByRole('button', { name: /^Fresh lamp, / })).toBeVisible()
    await expect(page.getByRole('button', { name: /^Fresh lamp, / })).toBeDisabled()
    assert.deepEqual(app.errors, [])
  } finally { await app.context.close() }

  // A prior connection's success cannot replace the state read after an
  // explicit reconnect. The retained workspace keeps edits during the outage.
  const next = await mockApp(browser, origin, { crossOrigin: true })
  try {
    const { page, handlers } = next
    const gate = deferred(), started = deferred(), completed = deferred()
    let oldCount = 0, oldConnection = true
    handlers.poll = async route => {
      if (oldConnection) {
        if (++oldCount === 1) {
          started.resolve()
          await gate.promise
          const old = initialState(); old.devices[0].name = 'Obsolete bridge lamp'
          await route.fulfill({ json: old }); completed.resolve(); return
        }
        return route.abort('connectionrefused')
      }
      next.state.devices[0].name = 'New bridge lamp'
      return route.fulfill({ json: next.state })
    }
    await page.clock.runFor(1500); await started.promise
    await page.clock.runFor(1500)
    await page.getByText(/Reconnecting automatically/).waitFor()
    oldConnection = false
    await page.getByRole('button', { name: 'Reconnect now', exact: true }).click()
    await page.getByRole('button', { name: /^New bridge lamp, / }).waitFor()
    gate.resolve(); await completed.promise
    await page.clock.runFor(300)
    await expect(page.getByRole('button', { name: /^New bridge lamp, / })).toBeVisible()
    await expect(page.getByRole('button', { name: /^Obsolete bridge lamp, / })).toHaveCount(0)
    assert.deepEqual(next.errors, [])
  } finally { await next.context.close() }
}

async function reviewPendingScope(browser, origin) {
  const app = await mockApp(browser, origin, { prepareState: state => {
    state.rooms = [
      { id: 'lampRoom', name: 'Lamp room', lightIDs: ['lifx:test'], schedules: [] },
      { id: 'wallRoom', name: 'Wall room', lightIDs: ['nanoleaf:TEST'], schedules: [] },
    ]
  } })
  try {
    const { page, handlers } = app
    await page.getByLabel('Control room').selectOption('lampRoom')
    await page.getByRole('button', { name: 'Music', exact: true }).click()
    const gate = deferred(), started = deferred(), completed = deferred()
    const old = structuredClone(app.state)
    old.devices[1].controlRevision = 99
    let reads = 0
    handlers.poll = async route => {
      if (++reads === 1) {
        started.resolve()
        await gate.promise
        await route.fulfill({ json: old })
        completed.resolve()
        return
      }
      return route.fulfill({ json: app.state })
    }
    await page.getByRole('button', { name: 'Demo groove', exact: true }).click()
    await page.getByRole('button', { name: 'Start', exact: true }).click()
    await started.promise
    await expect(page.getByLabel('Control room')).toBeDisabled()
    assert.equal(frames(app).length, 0, 'a pending baseline read must not render lighting')
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect(page.getByLabel('Control room')).toBeEnabled()
    await page.getByLabel('Control room').selectOption('wallRoom')
    // The bridge's new reading differs from the cached UI and the old request.
    Object.assign(app.state.devices[1], { color: { r: 15, g: 25, b: 35 }, brightness: 37, controlRevision: 4 })
    const expectedBaseline = baseline(app.state).filter(state => state.fixtureID === 'nanoleaf:TEST')
    await startDemo(app)
    gate.resolve(); await completed.promise
    await page.getByText(/Running · Demo groove/).waitFor()
    await page.clock.runFor(300)
    await expect.poll(() => frames(app).length).toBeGreaterThan(0)
    assert.ok(frames(app).every(command => command.data.states.every(state => state.fixtureID === 'nanoleaf:TEST' && state.controlRevision === 4)),
      'a cancelled baseline read cannot revive the old room or overwrite the new room’s fresh control revisions')
    await page.getByRole('button', { name: 'Stop', exact: true }).click()
    await expect.poll(() => restores(app).length).toBe(1)
    assert.deepEqual(restores(app)[0].data.states.map(state => state.fixtureID), ['nanoleaf:TEST'])
    assert.deepEqual(restores(app)[0].data.states.map(({ fixtureID, rgb, brightness }) => ({ fixtureID, rgb, brightness })), expectedBaseline,
      'Start must restore the bridge’s fresh light output, not a stale UI snapshot')
    assert.deepEqual(app.errors, [])
  } finally { await app.context.close() }
}

export async function reviewLifecycles(browser, origin) {
  await reviewPainting(browser, origin)
  await reviewMusic(browser, origin)
  await reviewPendingScope(browser, origin)
  await reviewPolling(browser, origin)
  console.log('LIFECYCLE_ASSERTIONS_PASS: rejected painting/retry, pending edits, explicit source Start/Restart, failed-source restore, restart/cancellation, pending room lock and cancellation, fresh baseline and revisions, stale polling and reconnect generation')
}

// Also runnable on its own with the optional Playwright packages used by CI.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '4175'], { stdio: 'pipe' })
  let browser
  try {
    const origin = 'http://127.0.0.1:4175'
    for (let attempt = 0; attempt < 80; attempt++) {
      try { await fetch(origin); break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
    }
    const executablePath = process.env.LUMENDESK_CHROMIUM_EXECUTABLE ?? process.env.LUMENDESK_CHROMIUM_PATH
    browser = await chromium.launch(executablePath ? { executablePath } : {})
    await reviewLifecycles(browser, origin)
  } finally { await browser?.close(); server.kill() }
}
