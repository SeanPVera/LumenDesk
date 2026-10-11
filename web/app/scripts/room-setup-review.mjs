// Exercise the production App's setup and discovery against deterministic
// bridge failures. Run from web/app with the visual-review dependencies.
import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import { mkdir, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'

const port = 4178
const origin = `http://127.0.0.1:${port}`
const output = `${process.env.LUMENDESK_WEB_QA_DIRECTORY ?? '/tmp/LumenDesk-Web-QA'}/room-setup`
await mkdir(output, { recursive: true })
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE }
  : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 1100, height: 900 } })
const page = await context.newPage()
page.setDefaultTimeout(10_000)
const errors = []
page.on('pageerror', error => errors.push(error.message))

const devices = [
  { id: 'lifx:one', name: 'Reading lamp', brand: 'lifx', ip: '192.0.2.1', reachable: true, lastSeen: Date.now() - 30_000, power: false, brightness: 65, color: { r: 255, g: 190, b: 100 }, kelvin: 3000 },
  { id: 'govee:two', name: 'Bookshelf strip', brand: 'govee', ip: '192.0.2.2', reachable: true, lastSeen: Date.now() - 30_000, power: true, brightness: 35, color: { r: 83, g: 152, b: 182 }, kelvin: 4000 },
]
const state = { devices, rooms: [], scenes: [], favorites: [] }
const commands = []
const probe = patch => ({ interfaces: ['Wi-Fi'], sent: 253, failed: 0, unoccupied: 250, lastError: null, ...patch })
let discoveryKind = 'blocked'
let failingPath = null
let delayedPath = null
let roomNumber = 0

await page.route('**/*', async route => {
  const url = new URL(route.request().url())
  const path = url.pathname
  if (!['/health', '/state', '/discover', '/rooms', '/nanoleaf/pair'].includes(path) && !path.startsWith('/devices/')) return route.continue()
  let response = path === '/health' ? { ok: true, service: 'lumendesk-bridge' } : path === '/state' ? state : { ok: true }
  if (route.request().method() === 'POST') {
    const data = route.request().postDataJSON() ?? {}
    commands.push({ path, data })
    if (path === delayedPath) await new Promise(resolve => setTimeout(resolve, 700))
    if (path === failingPath) return route.fulfill({ status: 503, json: { error: 'Simulated save failure.' } })
    if (path === '/discover') {
      // Keep stale reachable readings unless an actual answer is simulated.
      devices.forEach(device => { device.lastSeen = Date.now() - 30_000 })
      if (discoveryKind === 'partial') devices[0].lastSeen = Date.now()
      if (discoveryKind === 'ready') devices.forEach(device => { device.lastSeen = Date.now() })
      response = { ok: true, probes: {
        lifx: discoveryKind === 'blocked' ? probe({ sent: 0, failed: 3, lastError: 'ENETUNREACH' }) : probe(),
        govee: discoveryKind === 'blocked' ? probe({ sent: 0 }) : discoveryKind === 'partial' ? { error: 'socket unavailable' } : probe(),
        // Refresh counts must not hide failed LIFX/Govee network probes.
        nanoleaf: { sent: 1, paired: 1 },
      } }
    }
    if (path === '/rooms') {
      const room = { id: `created-${++roomNumber}`, name: data.name, lightIDs: [], schedules: [] }
      state.rooms.push(room)
      response = { room }
    }
    const assignment = path.match(/^\/devices\/([^/]+)\/room$/)
    if (assignment) {
      const device = devices.find(candidate => candidate.id === decodeURIComponent(assignment[1]))
      const assignedRoom = state.rooms.find(room => room.id === data.roomID)
      if (!assignedRoom) return route.fulfill({ status: 404, json: { error: 'Room not found.' } })
      state.rooms.forEach(room => { room.lightIDs = room.lightIDs.filter(id => id !== device.id) })
      device.roomID = data.roomID
      assignedRoom.lightIDs.push(device.id)
      response = { devices, rooms: state.rooms }
    }
    const control = path.match(/^\/devices\/([^/]+)\/(power|brightness)$/)
    if (control) {
      const device = devices.find(candidate => candidate.id === decodeURIComponent(control[1]))
      if (control[2] === 'power') device.power = data.on
      if (control[2] === 'brightness') device.brightness = data.value
      response = { device }
    }
    if (path === '/nanoleaf/pair') return route.fulfill({ status: 403, json: { error: 'Open the controller’s pairing window and try again.' } })
  }
  await route.fulfill({ json: response })
})

const count = path => commands.filter(command => command.path === path).length
const controls = () => commands.filter(command => /\/(power|brightness|color)$/.test(command.path))
const duplicateSubmit = form => form.evaluate(element => element.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
const deleteRoomElsewhere = roomID => {
  state.rooms = state.rooms.filter(room => room.id !== roomID)
  devices.forEach(device => { if (device.roomID === roomID) device.roomID = null })
}
async function audit(name) {
  await page.setViewportSize({ width: 390, height: 844 })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false, `${name} must fit a phone viewport`)
  await page.screenshot({ path: `${output}/${name}.png`, fullPage: true })
  const result = await new AxeBuilder({ page }).analyze()
  await writeFile(`${output}/${name}-accessibility.json`, JSON.stringify(result, null, 2))
  assert.deepEqual(result.violations.map(item => item.id), [], `${name} must be accessible`)
}

try {
  for (let attempt = 0; attempt < 80; attempt++) {
    try { await fetch(origin); break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  await page.goto(origin)
  const wizard = page.locator('.room-setup')
  await expect(wizard.getByRole('heading', { name: 'Find lights', exact: true })).toBeVisible()
  assert.equal(controls().length, 0, 'initial setup must not change lighting')
  await audit('find-lights')

  await wizard.getByRole('button', { name: 'Find lights', exact: true }).click()
  await expect(wizard.getByText('Discovery could not send network probes', { exact: true })).toBeVisible()
  await expect(wizard.getByText(/No discovery probes were sent/)).toBeVisible()
  await expect(wizard.getByText(/enable LAN Control/)).toBeVisible()
  await expect(wizard.getByText(/local network permission for the bridge/)).toBeVisible()
  await wizard.getByText('Discovery details', { exact: true }).click()
  await expect(wizard.getByText('LIFX: ENETUNREACH', { exact: true })).toBeVisible()
  await audit('blocked-discovery')

  discoveryKind = 'partial'
  await wizard.getByRole('button', { name: 'Find lights', exact: true }).click()
  await expect(wizard.getByText('Some discovery requests failed', { exact: true })).toBeVisible()
  await expect(wizard.getByText(/1 light answered during this search/)).toBeVisible()
  discoveryKind = 'silent'
  await wizard.getByRole('button', { name: 'Find lights', exact: true }).click()
  await expect(wizard.getByText('Probes sent, no lights answered', { exact: true })).toBeVisible()
  discoveryKind = 'ready'
  await wizard.getByRole('button', { name: 'Find lights', exact: true }).click()
  await expect(wizard.getByText('Lights are available', { exact: true })).toBeVisible()
  await expect(wizard.getByText('2 lights answered during this search.', { exact: true })).toBeVisible()

  // Pairing errors keep the entered address available for a retry.
  await wizard.getByText('Prepare your lights and network', { exact: true }).click()
  await wizard.getByRole('button', { name: 'Pair a Nanoleaf wall', exact: true }).click()
  await wizard.getByLabel('Controller address', { exact: true }).fill('192.0.2.30')
  await wizard.getByRole('button', { name: 'Pair wall', exact: true }).click()
  await expect(wizard.getByRole('alert')).toContainText('Pairing failed')
  await expect(wizard.getByLabel('Controller address', { exact: true })).toHaveValue('192.0.2.30')

  await wizard.getByRole('button', { name: 'Continue to room', exact: true }).click()
  await wizard.getByLabel('Room name', { exact: true }).fill('Living room')
  failingPath = delayedPath = '/rooms'
  await wizard.getByRole('button', { name: 'Create room', exact: true }).click()
  await expect(wizard.getByRole('button', { name: 'Creating…', exact: true })).toBeDisabled()
  await duplicateSubmit(wizard.locator('form'))
  await expect(wizard.getByRole('alert')).toContainText('The room could not be saved')
  assert.equal(count('/rooms'), 1, 'pending room creation must block duplicate submissions')
  assert.equal(state.rooms.length, 0)
  await expect(wizard.getByLabel('Room name', { exact: true })).toHaveValue('Living room')
  await audit('failed-room-draft')

  await wizard.getByRole('button', { name: 'Pause setup', exact: true }).click()
  await expect(wizard).toHaveCount(0)
  await page.getByRole('button', { name: 'Set up room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Create room', exact: true })).toBeVisible()
  await expect(wizard.getByLabel('Room name', { exact: true })).toHaveValue('Living room')
  failingPath = delayedPath = null
  await wizard.getByRole('button', { name: 'Create room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Assign lights', exact: true })).toBeVisible()
  assert.equal(state.rooms.length, 1)

  await wizard.getByRole('checkbox', { name: 'Reading lamp', exact: true }).check()
  await wizard.getByRole('checkbox', { name: 'Bookshelf strip', exact: true }).check()
  failingPath = '/devices/govee%3Atwo/room'
  await wizard.getByRole('button', { name: 'Save lights and continue', exact: true }).click()
  await expect(wizard.getByRole('alert')).toContainText('1 light could not be assigned')
  await expect(wizard.getByRole('checkbox', { name: 'Reading lamp', exact: true })).toBeChecked()
  await expect(wizard.getByRole('checkbox', { name: 'Reading lamp', exact: true })).toBeDisabled()
  await expect(wizard.getByRole('checkbox', { name: 'Bookshelf strip', exact: true })).toBeChecked()
  assert.deepEqual(state.rooms[0].lightIDs, ['lifx:one'])
  assert.equal(count('/devices/lifx%3Aone/room'), 1)
  assert.equal(count('/devices/govee%3Atwo/room'), 1)
  await audit('partial-assignment')
  failingPath = null
  await wizard.getByRole('button', { name: 'Save lights and continue', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Try controls', exact: true })).toBeVisible()
  assert.equal(count('/devices/lifx%3Aone/room'), 1, 'retry must not repeat successful assignments')
  assert.equal(count('/devices/govee%3Atwo/room'), 2)
  assert.equal(controls().length, 0, 'entering Try controls must not change power, brightness or color')
  await audit('try-controls')

  await wizard.getByRole('button', { name: 'Turn on', exact: true }).click()
  await expect(wizard.getByText(/On request sent to Reading lamp/)).toBeVisible()
  assert.deepEqual(controls().map(command => ({ path: command.path, data: command.data })), [{ path: '/devices/lifx%3Aone/power', data: { on: true } }])
  await wizard.getByRole('slider', { name: /^Brightness/ }).fill('42')
  assert.equal(count('/devices/lifx%3Aone/brightness'), 0, 'staging brightness must not send a command')
  await wizard.getByRole('button', { name: 'Apply brightness', exact: true }).click()
  await expect(wizard.getByText(/42% brightness request sent to Reading lamp/)).toBeVisible()
  assert.equal(devices[0].brightness, 42)

  const createdID = state.rooms[0].id
  await wizard.getByRole('button', { name: 'Done, open room', exact: true }).click()
  await expect(wizard).toHaveCount(0)
  await expect(page.getByLabel('Control room', { exact: true })).toHaveValue(createdID)
  await expect(page.getByRole('heading', { name: 'Fixtures', exact: true })).toBeVisible()
  await audit('completed-room')

  // A room deleted by another client must release the saved wizard target.
  // Recover from Assign, keeping its name and previous fixture choices.
  await page.getByRole('button', { name: 'Set up room', exact: true }).click()
  await wizard.getByRole('button', { name: 'Continue to room', exact: true }).click()
  await wizard.getByLabel(/^Or use an existing room/).selectOption(createdID)
  await wizard.getByRole('button', { name: 'Use room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Assign lights', exact: true })).toBeVisible()
  const assignmentsBeforeDeletion = commands.filter(command => command.path.endsWith('/room')).length
  deleteRoomElsewhere(createdID)
  await expect(wizard.getByRole('heading', { name: 'Create room', exact: true })).toBeVisible()
  await expect(wizard.getByRole('alert')).toContainText('This room was deleted')
  await expect(wizard.getByLabel('Room name', { exact: true })).toHaveValue('Living room')
  await expect(wizard.getByRole('button', { name: 'Create room', exact: true })).toBeEnabled()
  assert.equal(commands.filter(command => command.path.endsWith('/room')).length, assignmentsBeforeDeletion, 'deletion recovery must not assign lights to the stale room')
  await wizard.getByRole('button', { name: 'Pause setup', exact: true }).click()
  await page.getByRole('button', { name: 'Set up room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Create room', exact: true })).toBeVisible()
  await expect(wizard.getByLabel('Room name', { exact: true })).toHaveValue('Living room')
  await wizard.getByRole('button', { name: 'Create room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Assign lights', exact: true })).toBeVisible()
  for (const name of ['Reading lamp', 'Bookshelf strip']) {
    await expect(wizard.getByRole('checkbox', { name, exact: true })).toBeChecked()
    await expect(wizard.getByRole('checkbox', { name, exact: true })).toBeEnabled()
  }
  await wizard.getByRole('button', { name: 'Save lights and continue', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Try controls', exact: true })).toBeVisible()
  const recreatedID = state.rooms[0].id
  assert.notEqual(recreatedID, createdID, 'the same room name must resolve to a new saved ID')
  assert.deepEqual(state.rooms[0].lightIDs.sort(), ['govee:two', 'lifx:one'])

  // The same recovery also works from Try and while the wizard is paused.
  const controlsBeforeDeletion = controls().length
  deleteRoomElsewhere(recreatedID)
  await expect(wizard.getByRole('heading', { name: 'Create room', exact: true })).toBeVisible()
  await expect(wizard.getByRole('alert')).toContainText('This room was deleted')
  await expect(wizard.getByLabel('Room name', { exact: true })).toHaveValue('Living room')
  await audit('deleted-room-recovery')
  await wizard.getByRole('button', { name: 'Create room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Assign lights', exact: true })).toBeVisible()
  await wizard.getByRole('button', { name: 'Save lights and continue', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Try controls', exact: true })).toBeVisible()
  const pausedID = state.rooms[0].id
  await wizard.getByRole('button', { name: 'Pause setup', exact: true }).click()
  deleteRoomElsewhere(pausedID)
  await expect(page.getByLabel('Control room', { exact: true }).locator('option', { hasText: 'Living room' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Set up room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Create room', exact: true })).toBeVisible()
  await expect(wizard.getByLabel('Room name', { exact: true })).toHaveValue('Living room')
  await wizard.getByRole('button', { name: 'Create room', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Assign lights', exact: true })).toBeVisible()
  await wizard.getByRole('button', { name: 'Save lights and continue', exact: true }).click()
  await expect(wizard.getByRole('heading', { name: 'Try controls', exact: true })).toBeVisible()
  assert.equal(controls().length, controlsBeforeDeletion, 'deleted-room recovery and recreation must not change lighting')
  const recoveredID = state.rooms[0].id
  await wizard.getByRole('button', { name: 'Done, open room', exact: true }).click()
  await expect(page.getByLabel('Control room', { exact: true })).toHaveValue(recoveredID)
  assert.deepEqual(errors, [])

  // Editing a bridge port must leave the current connection alone until Connect.
  const portContext = await browser.newContext({ viewport: { width: 390, height: 844 } })
  const portPage = await portContext.newPage()
  const healthRequests = []
  let connectedPort = false
  await portPage.route('**/*', async route => {
    const url = new URL(route.request().url())
    if (!['/health', '/state'].includes(url.pathname)) return route.continue()
    if (url.pathname === '/health') healthRequests.push(url.href)
    if (url.origin === origin) return route.fulfill({ json: { service: 'preview-server' } })
    if (url.port !== '9387') return route.abort('connectionrefused')
    connectedPort = true
    return route.fulfill({ json: url.pathname === '/health' ? { ok: true, service: 'lumendesk-bridge' } : { devices: [], rooms: [], scenes: [], favorites: [] } })
  })
  await portPage.goto(origin)
  await expect(portPage.getByRole('button', { name: 'Connect', exact: true })).toBeEnabled()
  const portInput = portPage.getByLabel('Bridge port', { exact: true })
  const healthBefore = healthRequests.length
  await portInput.fill('')
  await expect(portPage.getByRole('button', { name: 'Connect', exact: true })).toBeDisabled()
  await portInput.pressSequentially('9387', { delay: 60 })
  assert.equal(healthRequests.length, healthBefore, 'typing a partial port must not connect or reset the field')
  await expect(portInput).toHaveValue('9387')
  await portPage.getByRole('button', { name: 'Connect', exact: true }).click()
  await expect(portPage.getByRole('button', { name: 'Set up room', exact: true })).toBeVisible()
  assert.equal(connectedPort, true)
  assert.ok(healthRequests.includes('http://127.0.0.1:9387/health'))
  await portContext.close()
  console.log('ROOM_SETUP_ASSERTIONS_PASS: fresh discovery diagnostics, vendor and network preparation, pairing draft retention, room failure and duplicate guards, pause/reopen, partial assignment retry, explicit control commands, completed room scope, deleted-room recovery from Assign, Try and Pause, same-name recreation and retained fixture choices, Connect-only bridge port changes, 390px overflow and accessibility')
} finally {
  await browser.close()
  server.kill()
}
