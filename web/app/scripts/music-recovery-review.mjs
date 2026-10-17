// Production browser/HTTP lifecycle check: the vendor queue is simulated;
// the actual App, session storage, bridge ownership and watchdog run normally.
import { chromium, expect } from '@playwright/test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { Registry } from '../../bridge/src/registry.js'
import { createServer } from '../../bridge/src/server.js'

const registry = new Registry()
const id = 'lifx:recovery-review'
const starting = { hue: 1200, saturation: 23000, brightness: 43210, kelvin: 3000 }
registry.upsert(id, { name: 'Recovery lamp', ip: '127.0.0.1', power: true, brightness: 66,
  color: { r: 220, g: 150, b: 80 }, kelvin: 3000, hsbk: { ...starting } })
let refuseRestore = false
const writes = []
const client = {
  setColor(device, command) {
    if (command.hsbk && refuseRestore) return false
    writes.push(structuredClone(command))
    if (command.hsbk) registry.patch(device.id, { hsbk: { ...command.hsbk } })
    return true
  },
  discover: async () => ({ sent: 1 }), refresh() {}, setPower: () => true, setBrightness: () => true,
}
const staticDir = fileURLToPath(new URL('../dist', import.meta.url))
const server = createServer({ registry, lifx: client, govee: client, allowedOrigins: [], version: 'review', staticDir })
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
const origin = `http://127.0.0.1:${server.address().port}`
const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8')
const moduleSource = html.match(/<script\b[^>]*\bsrc=["']([^"']+)["']/)?.[1]
assert.ok(moduleSource, 'Build the production app before running the recovery review')
const assetPath = new URL(moduleSource, origin).pathname
const appURL = `${origin}${assetPath.slice(0, assetPath.lastIndexOf('/assets/') + 1)}`
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE } : {})
const context = await browser.newContext()
await context.addInitScript(() => window.localStorage.setItem('LumenDesk.roomSetupDismissed.v1', 'true'))
const errors = []
const network = []
context.on('request', request => {
  const path = new URL(request.url()).pathname
  if (path === '/state' || path === '/music/frame') {
    network.push({ at: Date.now(), path, states: path === '/music/frame' ? request.postDataJSON()?.states : undefined })
    if (network.length > 20) network.shift()
  }
})
const newPage = async ({ pageContext = context } = {}) => {
  const page = await pageContext.newPage()
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(appURL)
  await page.getByRole('button', { name: 'Music', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Start', exact: true })).toBeEnabled()
  return page
}
const start = async (page, { beforeClaimed } = {}) => {
  await page.bringToFront()
  await expect(page.getByLabel('Role for Recovery lamp', { exact: true })).toBeVisible()
  await expect(page.getByText('1 included light · 0 left out', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Demo groove', exact: true }).click()
  await page.getByRole('button', { name: 'Start', exact: true }).click()
  try {
    if (beforeClaimed) await beforeClaimed()
    await expect.poll(() => registry.get(id).musicOwner).toBeTruthy()
  } catch (error) {
    console.error('MUSIC_START_DIAGNOSTICS', JSON.stringify({
      device: registry.get(id), now: Date.now(), errors, network,
      page: await page.evaluate(() => ({ visibility: document.visibilityState, time: Date.now(),
        performance: performance.now(), transport: document.querySelector('.music-transport-controls')?.textContent,
        details: document.querySelector('.music-transport')?.textContent,
        fixtures: document.querySelector('.fixture-list')?.textContent,
        storage: window.sessionStorage.getItem('lumendesk.music-recovery.v1') })),
    }))
    throw error
  }
  await expect(page.locator('.music-transport-controls')).toContainText('Running · Demo groove')
}

try {
  const page = await newPage()
  await start(page)
  const firstOwner = registry.get(id).musicOwner
  const beforeReload = registry.get(id).controlRevision
  assert.equal(await page.evaluate(() => window.sessionStorage.getItem('lumendesk.music-recovery.v1')), null,
    'an active show must not be persisted as pending cleanup')
  const clonedStorage = await page.evaluate(() => Object.entries(window.sessionStorage))
  const duplicate = await context.newPage()
  await duplicate.addInitScript(entries => entries.forEach(([key, value]) => window.sessionStorage.setItem(key, value)), clonedStorage)
  await duplicate.goto(appURL)
  await expect(duplicate.getByRole('button', { name: 'Start', exact: true })).toBeEnabled()
  assert.equal(registry.get(id).musicOwner, firstOwner, 'a duplicate tab cannot restore/release the original live show')
  await duplicate.close()
  await page.reload()
  await expect.poll(() => registry.get(id).musicOwner, { timeout: 8000 }).toBeNull()
  assert.equal(registry.get(id).controlRevision, beforeReload + 1)
  assert.deepEqual(writes.at(-1).hsbk, starting)
  await expect.poll(() => page.evaluate(() => window.sessionStorage.getItem('lumendesk.music-recovery.v1'))).toBeNull()

  await start(page)
  await page.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect.poll(() => registry.get(id).musicOwner).toBeNull()

  // Isolate emulated timers to this scenario. Reload/closure cases use the
  // browser's real clock alongside the bridge's real recovery timer.
  // Playwright's clock is shared across pages in one context.
  const pausedContext = await browser.newContext()
  await pausedContext.addInitScript(() => window.localStorage.setItem('LumenDesk.roomSetupDismissed.v1', 'true'))
  const pausedPage = await newPage({ pageContext: pausedContext })
  await start(pausedPage)
  // Use the emulated browser's clock, installing it after show start so initial
  // page load and connection checks complete with the real clock first.
  await pausedPage.clock.install()
  await pausedPage.clock.pauseAt(await pausedPage.evaluate(() => Date.now() + 1000))
  await expect.poll(() => registry.get(id).musicOwner, { timeout: 8000 }).toBeNull()
  await pausedPage.clock.resume()
  await expect(pausedPage.getByRole('alert')).toContainText('Music stopped because the bridge released these lights')
  await expect(pausedPage.getByRole('button', { name: 'Start', exact: true })).toBeEnabled()
  await pausedContext.close()

  await start(page)
  assert.notEqual(registry.get(id).musicOwner, firstOwner)
  refuseRestore = true
  await page.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('Retry when the lights reconnect')
  await page.reload()
  await expect(page.getByRole('alert')).toContainText('Retry when the lights reconnect')
  assert.ok(await page.evaluate(() => window.sessionStorage.getItem('lumendesk.music-recovery.v1')))
  refuseRestore = false
  await page.getByRole('button', { name: 'Retry now', exact: true }).click()
  await expect.poll(() => registry.get(id).musicOwner).toBeNull()
  await expect.poll(() => page.evaluate(() => window.sessionStorage.getItem('lumendesk.music-recovery.v1'))).toBeNull()

  // A heartbeat can overtake a delayed first output request. An unclaimed
  // light with the captured revision is still available to the new show.
  let releaseFirstFrame
  const heldFirstFrame = new Promise(resolve => { releaseFirstFrame = resolve })
  let firstFrameHeld = false, earlyHeartbeatFinished = false
  await page.route('**/music/frame', async route => {
    const states = route.request().postDataJSON().states
    if (!firstFrameHeld && states.some(state => !state.heartbeat && !state.restoring)) {
      firstFrameHeld = true
      await heldFirstFrame
      await route.continue()
    } else if (states.some(state => state.heartbeat) && !registry.get(id).musicOwner) {
      const response = await route.fetch()
      assert.equal((await response.json()).rejectedOwnership, undefined)
      await route.fulfill({ response })
      earlyHeartbeatFinished = true
    } else await route.continue()
  })
  await start(page, { beforeClaimed: async () => {
    await expect.poll(() => firstFrameHeld).toBe(true)
    await expect.poll(() => earlyHeartbeatFinished).toBe(true)
    await expect(page.locator('.music-transport-controls')).toContainText('Running · Demo groove')
    releaseFirstFrame()
  } })
  await page.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect.poll(() => registry.get(id).musicOwner).toBeNull()
  await page.unroute('**/music/frame')

  // The heartbeat request is independent of the frame sender's drain. Hold
  // one across Stop/Start; its late rejection must not stop the new show.
  let releaseHeartbeat
  const heldHeartbeat = new Promise(resolve => { releaseHeartbeat = resolve })
  let heartbeatHeld = false, heartbeatFinished = false
  await page.route('**/music/frame', async route => {
    const states = route.request().postDataJSON().states
    if (!heartbeatHeld && states.some(state => state.heartbeat)) {
      heartbeatHeld = true
      await heldHeartbeat
      const response = await route.fetch()
      assert.deepEqual((await response.json()).rejectedOwnership, [id])
      await route.fulfill({ response })
      heartbeatFinished = true
    } else await route.continue()
  })
  await start(page)
  await expect.poll(() => heartbeatHeld).toBe(true)
  await page.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect.poll(() => registry.get(id).musicOwner).toBeNull()
  await start(page)
  releaseHeartbeat()
  await expect.poll(() => heartbeatFinished).toBe(true)
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
  await expect(page.locator('.music-transport-controls')).toContainText('Running · Demo groove')
  await page.unroute('**/music/frame')

  const writesBeforeClose = writes.length
  const expected = structuredClone(registry.get(id).hsbk)
  await page.close()
  await expect.poll(() => registry.get(id).musicOwner, { timeout: 8000 }).toBeNull()
  assert.ok(writes.length > writesBeforeClose)
  assert.deepEqual(writes.at(-1).hsbk, expected, 'bridge recovery uses the exact stored starting HSBK after the page vanishes')
  assert.deepEqual(errors, [])
  console.log('MUSIC_RECOVERY_ASSERTIONS_PASS: duplicate tab protection, active reload, failed-cleanup reload/retry, heartbeat before first output, late heartbeat across Stop/Start, suspended timer recovery/resume, page closure watchdog and original ownership/revision')
} finally {
  await context.close()
  await browser.close()
  server.closeAllConnections()
  await new Promise(resolve => server.close(resolve))
}
