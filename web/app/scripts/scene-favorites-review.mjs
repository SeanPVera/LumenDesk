// Exercise the real App against a deterministic bridge, including scene scope
// and failed persistence. Run from web/app with the visual-review dependencies.
import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'

const port = 4178
const origin = `http://127.0.0.1:${port}`
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE }
  : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 1100, height: 900 } })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))

const devices = [
  { id: 'lifx:alpha', name: 'Alpha lamp', brand: 'lifx', reachable: true, power: true, brightness: 60, color: { r: 255, g: 180, b: 100 }, kelvin: 3500, ip: '192.0.2.1', roomID: 'living' },
  { id: 'govee:beta', name: 'Beta lamp', brand: 'govee', reachable: true, power: true, brightness: 60, color: { r: 255, g: 180, b: 100 }, kelvin: 3500, ip: '192.0.2.2', roomID: 'living' },
  { id: 'lifx:corner', name: 'Corner lamp', brand: 'lifx', reachable: false, power: false, brightness: 40, color: { r: 200, g: 180, b: 255 }, kelvin: 4000, ip: '192.0.2.3', roomID: 'living' },
  { id: 'lifx:desk', name: 'Desk lamp', brand: 'lifx', reachable: true, power: true, brightness: 75, color: { r: 255, g: 255, b: 255 }, kelvin: 6500, ip: '192.0.2.4', roomID: 'office' },
]
const snapshot = device => ({ isOn: device.power, brightness: device.brightness, color: structuredClone(device.color), kelvin: device.kelvin })
const state = {
  devices, favorites: [],
  rooms: [
    { id: 'living', name: 'Living room', lightIDs: devices.slice(0, 3).map(device => device.id), schedules: [] },
    { id: 'office', name: 'Office', lightIDs: ['lifx:desk'], schedules: [] },
  ],
  scenes: [{
    id: 'everywhere', name: 'Everywhere', createdAt: '2026-10-01T00:00:00Z',
    snapshots: Object.fromEntries([...devices.map(device => [device.id, snapshot(device)]), ['lifx:gone', { isOn: false, brightness: 10, color: null, kelvin: 3000 }]]),
  }],
}
const commands = []
let failScene = false
let delayScene = false
let nextScene = 0

await page.route('**/*', async route => {
  const path = new URL(route.request().url()).pathname
  if (!['/state', '/health', '/scenes'].includes(path) && !path.startsWith('/devices/') && !path.startsWith('/scenes/')) return route.continue()
  if (path === '/health') return route.fulfill({ json: { ok: true, service: 'lumendesk-bridge' } })
  if (path === '/state') return route.fulfill({ json: state })
  const data = route.request().postDataJSON() ?? {}
  commands.push({ path, data })

  if (path === '/scenes') {
    if (delayScene) await new Promise(resolve => setTimeout(resolve, 700))
    if (failScene) return route.fulfill({ status: 503, json: { error: 'Simulated scene save failure.' } })
    const scene = {
      id: `capture-${++nextScene}`, name: data.name, createdAt: '2026-10-11T12:00:00Z',
      snapshots: Object.fromEntries(data.deviceIDs.map(id => [id, snapshot(devices.find(device => device.id === id))])),
    }
    state.scenes.push(scene)
    return route.fulfill({ json: { scene } })
  }

  const sceneApply = path.match(/^\/scenes\/([^/]+)\/apply$/)
  if (sceneApply) {
    const scene = state.scenes.find(item => item.id === sceneApply[1])
    const applied = []
    const skipped = []
    for (const [id, saved] of Object.entries(scene.snapshots)) {
      const device = devices.find(item => item.id === id)
      if (!device?.reachable) { skipped.push(id); continue }
      Object.assign(device, { power: saved.isOn, brightness: saved.brightness, color: saved.color, kelvin: saved.kelvin })
      applied.push(id)
    }
    return route.fulfill({ json: { applied, skipped, devices } })
  }

  const match = path.match(/^\/devices\/([^/]+)\/(favorite|power|brightness|color)$/)
  assert.ok(match, `Unexpected bridge command: ${path}`)
  const device = devices.find(item => item.id === decodeURIComponent(match[1]))
  assert.ok(device, `Unknown commanded fixture: ${match[1]}`)
  if (match[2] === 'favorite') {
    device.favorite = !device.favorite
    state.favorites = devices.filter(item => item.favorite).map(item => item.id)
    return route.fulfill({ json: { devices, rooms: state.rooms } })
  }
  if (match[2] === 'power') device.power = data.on
  if (match[2] === 'brightness') device.brightness = data.value
  if (match[2] === 'color') {
    if (data.rgb) device.color = data.rgb
    if (data.kelvin) device.kelvin = data.kelvin
  }
  return route.fulfill({ json: { device } })
})

const count = path => commands.filter(command => command.path === path).length
const commandedIDs = suffix => commands.filter(command => command.path.endsWith(suffix)).map(command => decodeURIComponent(command.path.split('/')[2])).sort()
const noOverflow = async () => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false, 'scene/favorites view must fit a narrow screen')

try {
  let ready = false
  for (let attempt = 0; attempt < 80; attempt++) {
    try { await fetch(origin); ready = true; break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  assert.equal(ready, true, 'Vite did not start')
  await page.goto(origin)
  await page.getByLabel('Control room').selectOption('living')

  // Starring a fixture has a visible destination, and filtered controls cannot
  // send commands to the other fixtures in this room or another room.
  await page.getByRole('button', { name: 'Add Alpha lamp to favorites', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Remove Alpha lamp from favorites', exact: true })).toHaveAttribute('aria-pressed', 'true')
  await page.getByRole('button', { name: /^★ Favorites/ }).click()
  await expect(page.locator('.fixture-rows li')).toHaveCount(1)
  await expect(page.locator('.output-controls')).toContainText('changes apply to visible fixtures only')
  commands.length = 0
  await page.getByRole('button', { name: 'Off', exact: true }).click()
  await expect.poll(() => commandedIDs('/power')).toEqual(['lifx:alpha'])
  await page.getByRole('slider', { name: /^Brightness/ }).fill('43')
  await expect.poll(() => commandedIDs('/brightness')).toEqual(['lifx:alpha'])
  assert.equal(devices.find(device => device.id === 'govee:beta').power, true)
  assert.equal(devices.find(device => device.id === 'lifx:desk').brightness, 75)

  // Removing the last favorite gives a next step and disables empty controls.
  await page.getByRole('button', { name: 'Remove Alpha lamp from favorites', exact: true }).click()
  await expect(page.getByText('No favorites in this room yet. Choose All fixtures, then use a star beside a fixture.')).toBeVisible()
  await expect(page.getByRole('button', { name: 'On', exact: true })).toBeDisabled()
  await page.getByRole('button', { name: /^All fixtures/ }).click()

  // Hidden selections are retained visibly as a count but excluded from output
  // commands, so a search cannot quietly change another light.
  await page.getByRole('button', { name: /^Alpha lamp, / }).click()
  await page.getByRole('button', { name: /^Beta lamp, / }).click()
  await page.getByRole('searchbox', { name: 'Find a fixture' }).fill('Alpha')
  await expect(page.getByText('1 selected fixture is hidden by your filters and excluded from changes.')).toBeVisible()
  commands.length = 0
  await page.getByRole('button', { name: 'On', exact: true }).click()
  await expect.poll(() => commandedIDs('/power')).toEqual(['lifx:alpha'])

  // The room-side capture affordance states that capture includes the complete
  // room; its request includes both filtered-out and unavailable fixtures.
  await page.locator('.scene-capture summary').click()
  const capture = page.locator('.scene-capture-form')
  await expect(capture).toContainText('all 3 fixtures in Living room')
  await expect(capture).toContainText('including fixtures hidden by a filter or outside your selection')
  const sceneName = capture.getByRole('textbox', { name: 'Scene name', exact: true })
  await sceneName.fill('Full room')
  await capture.getByRole('button', { name: 'Save scene', exact: true }).click()
  await expect(sceneName).toHaveValue('')
  assert.deepEqual(commands.find(command => command.path === '/scenes').data.deviceIDs.sort(), ['govee:beta', 'lifx:alpha', 'lifx:corner'])
  assert.deepEqual(Object.keys(state.scenes.find(scene => scene.name === 'Full room').snapshots).sort(), ['govee:beta', 'lifx:alpha', 'lifx:corner'])

  // Failed capture keeps the name and guards duplicate submissions while the
  // request is pending; retry saves the same draft and clears it only on success.
  failScene = delayScene = true
  await sceneName.fill('Kept draft')
  const savesBefore = count('/scenes')
  await capture.getByRole('button', { name: 'Save scene', exact: true }).click()
  await expect(capture.getByRole('button', { name: 'Saving…', exact: true })).toBeDisabled()
  await capture.locator('form').evaluate(form => form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
  await expect(capture.getByRole('status')).toContainText('The scene was not saved')
  assert.equal(count('/scenes'), savesBefore + 1, 'pending capture must block duplicate requests')
  await expect(sceneName).toHaveValue('Kept draft')
  assert.equal(state.scenes.some(scene => scene.name === 'Kept draft'), false)
  failScene = delayScene = false
  await capture.getByRole('button', { name: 'Save scene', exact: true }).click()
  await expect(sceneName).toHaveValue('')
  assert.equal(state.scenes.filter(scene => scene.name === 'Kept draft').length, 1)

  // Saved fixture/room scope is visible before any recall. Scope follows saved
  // IDs, including a known fixture outside the currently selected room.
  await page.getByRole('button', { name: 'Scenes', exact: true }).click()
  const everywhere = page.locator('.composition').filter({ has: page.getByRole('heading', { name: 'Everywhere', exact: true }) })
  const scope = everywhere.locator('.scene-scope')
  await expect(scope).toContainText('Current rooms: Living room (3), Office (1), Unknown room (1).')
  await expect(scope).toContainText('1 saved fixture outside Living room will also be recalled.')
  assert.equal(count('/scenes/everywhere/apply'), 0, 'reading scene scope must not recall lighting')
  await scope.locator('summary').click()
  const savedFixture = name => scope.locator('.scene-fixture-list li').filter({ hasText: name })
  await expect(savedFixture('Desk lamp')).toContainText('Desk lamp · Office')
  await expect(savedFixture('Desk lamp')).toContainText('Outside Living room')
  await expect(savedFixture('Desk lamp')).toContainText('On · 75% brightness')
  await expect(savedFixture('Beta lamp')).toContainText('3500 K white')

  // Unavailable and missing fixtures are identified separately from another
  // room. Selecting All lights never describes a missing ID as outside it.
  await expect(scope).toContainText('2 unavailable fixtures may be skipped.')
  await expect(savedFixture('Corner lamp')).toContainText('Corner lamp · Living room')
  await expect(savedFixture('Corner lamp')).toContainText('Off · 40% brightness')
  await expect(savedFixture('Corner lamp')).toContainText('Unavailable')
  await expect(savedFixture('Unavailable fixture (lifx:gone)')).toContainText('Unknown room')
  await expect(savedFixture('Unavailable fixture (lifx:gone)')).toContainText('Unavailable')
  await everywhere.getByRole('button', { name: 'Apply', exact: true }).click()
  await expect(page.locator('.toast')).toContainText('sent to 3 lights · 2 skipped')
  assert.equal(count('/scenes/everywhere/apply'), 1)
  await page.getByLabel('Control room').selectOption('all')
  await expect(scope).not.toContainText('outside All lights')
  await expect(scope).toContainText('Recall uses the saved fixtures shown below.')

  await page.setViewportSize({ width: 390, height: 844 })
  await noOverflow()
  const sceneAxe = await new AxeBuilder({ page }).analyze()
  assert.deepEqual(sceneAxe.violations.map(violation => violation.id), [], 'scene capture and scope must be accessible')
  await page.getByRole('button', { name: 'Light', exact: true }).click()
  await noOverflow()
  const roomAxe = await new AxeBuilder({ page }).analyze()
  assert.deepEqual(roomAxe.violations.map(violation => violation.id), [], 'favorites filters and star controls must be accessible')
  assert.deepEqual(errors, [], 'the production App must not throw browser errors')
  console.log('SCENE_FAVORITES_ASSERTIONS_PASS: favorite destination and filtered command scope, hidden selection exclusion, complete room capture, failed draft retention and duplicate guards, saved fixture/room recall scope, unavailable and unknown fixture identification, narrow-screen overflow and accessibility')
} finally {
  await browser.close()
  server.kill()
}
