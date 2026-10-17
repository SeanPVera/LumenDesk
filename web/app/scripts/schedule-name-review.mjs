// Exercise the production App against a bridge with deterministic persistence
// failures. Run from web/app after installing the visual-review dependencies.
import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'

const port = 4177
const origin = `http://127.0.0.1:${port}`
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE }
  : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', String(port), '--strictPort'], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 1100, height: 900 } })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))

const device = { id: 'lifx:one', name: 'Reading lamp', brand: 'lifx', ip: '192.0.2.1', reachable: true, power: true, brightness: 65, color: { r: 255, g: 190, b: 100 }, kelvin: 3000, roomID: 'lounge' }
const initialSchedule = { id: 'reading', hour: 21, minute: 15, action: 'applyScene', weekdays: [2, 4, 6], sceneID: 'evening', isEnabled: true }
const state = {
  devices: [device], favorites: [],
  rooms: [{ id: 'lounge', name: 'Living room', lightIDs: [device.id], schedules: [structuredClone(initialSchedule)] }],
  scenes: ['evening', 'dawn'].map((id, index) => ({ id, name: index ? 'Morning' : 'Late reading', createdAt: '2026-09-24T00:00:00Z', snapshots: { [device.id]: structuredClone(device) } })),
}
const commands = []
let failingPath = null
let delayedPath = null
let newSchedule = 0

await page.route('**/*', async route => {
  const url = new URL(route.request().url())
  const path = url.pathname
  if (!['/health', '/state', '/discover'].includes(path) && !path.startsWith('/devices/') && !path.startsWith('/rooms/')) return route.continue()
  let response = path === '/health' ? { ok: true, service: 'lumendesk-bridge' } : path === '/state' ? state : { ok: true }
  if (route.request().method() === 'POST') {
    const data = route.request().postDataJSON() ?? {}
    const operation = path + url.search
    commands.push({ path: operation, data })
    if (operation === delayedPath) await new Promise(resolve => setTimeout(resolve, 700))
    if (operation === failingPath) return route.fulfill({ status: 503, json: { error: 'Simulated save failure.' } })
    if (path.endsWith('/rename')) {
      device.name = data.name
      response = { devices: state.devices, rooms: state.rooms }
    }
    const match = path.match(/^\/rooms\/lounge\/schedules(?:\/([^/]+))?$/)
    if (match) {
      const room = state.rooms[0]
      if (!match[1]) {
        const schedule = { id: `new-${++newSchedule}`, isEnabled: true, ...data }
        room.schedules.push(schedule)
        response = { schedule }
      } else if (url.searchParams.has('delete')) {
        room.schedules = room.schedules.filter(schedule => schedule.id !== match[1])
        response = { ok: true }
      } else {
        const schedule = room.schedules.find(schedule => schedule.id === match[1])
        Object.assign(schedule, data)
        response = { schedule }
      }
    }
  }
  await route.fulfill({ json: response })
})

const count = path => commands.filter(command => command.path === path).length
const duplicateSubmit = form => form.evaluate(element => element.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })))
const noOverflow = async () => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false)

try {
  for (let attempt = 0; attempt < 80; attempt++) {
    try { await fetch(origin); break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  await page.goto(origin)
  await page.getByRole('button', { name: 'Devices', exact: true }).click()
  const nameForm = page.getByRole('form', { name: 'Name for Reading lamp', exact: true })
  await page.getByLabel('Rename Reading lamp').fill('Keep this draft')
  await page.getByLabel('Rename Reading lamp').blur()
  assert.equal(count('/devices/lifx%3Aone/rename'), 0, 'blur must not rename a light')
  await expect(nameForm.getByText('Unsaved changes', { exact: true })).toBeVisible()

  // A fresh reading must not discard edits; Cancel returns to the latest name.
  device.name = 'Changed on another browser'
  await expect(page.getByRole('form', { name: 'Name for Changed on another browser', exact: true })).toBeVisible()
  await expect(page.getByLabel('Rename Changed on another browser')).toHaveValue('Keep this draft')
  await page.getByRole('form', { name: 'Name for Changed on another browser', exact: true }).getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(page.getByLabel('Rename Changed on another browser')).toHaveValue(device.name)
  device.name = 'Reading lamp'
  await expect(page.getByLabel('Rename Reading lamp')).toHaveValue('Reading lamp')

  failingPath = delayedPath = '/devices/lifx%3Aone/rename'
  await page.getByLabel('Rename Reading lamp').fill('Desk lamp')
  await nameForm.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(nameForm.getByRole('button', { name: 'Saving…', exact: true })).toBeDisabled()
  await expect(nameForm.getByRole('button', { name: 'Cancel', exact: true })).toBeDisabled()
  await duplicateSubmit(nameForm)
  await expect(nameForm.getByRole('alert')).toContainText('Name was not saved')
  assert.equal(count(failingPath), 1, 'pending rename must block duplicate requests')
  await expect(page.getByLabel('Rename Reading lamp')).toHaveValue('Desk lamp')
  assert.equal(device.name, 'Reading lamp')
  failingPath = delayedPath = null
  await nameForm.getByRole('button', { name: 'Save', exact: true }).click()
  await expect(page.getByLabel('Rename Desk lamp')).toHaveValue('Desk lamp')
  await expect(page.getByText('Name saved', { exact: true })).toBeVisible()

  await page.getByRole('button', { name: 'Schedules', exact: true }).click()
  await page.getByRole('button', { name: 'Edit Apply scene at 21:15 in Living room', exact: true }).click()
  const editor = page.getByRole('form', { name: 'Edit schedule for Living room', exact: true })
  await expect(editor.getByLabel('Edit schedule time for Living room')).toHaveValue('21:15')
  await expect(editor.getByLabel('Edit schedule action for Living room')).toHaveValue('applyScene')
  await expect(editor.getByLabel('Edit schedule scene for Living room')).toHaveValue('evening')
  assert.deepEqual(await editor.locator('.day[aria-pressed=true]').allTextContents(), ['Mon', 'Wed', 'Fri'])
  await expect(page.getByRole('checkbox', { name: 'Enable Apply scene at 21:15 in Living room', exact: true })).toBeDisabled()

  await editor.getByLabel('Edit schedule time for Living room').fill('18:45')
  await editor.getByLabel('Edit schedule action for Living room').selectOption('dim25')
  await editor.getByRole('button', { name: 'Tue', exact: true }).click()
  failingPath = delayedPath = '/rooms/lounge/schedules/reading'
  const savesBefore = count(failingPath)
  await editor.getByRole('button', { name: 'Save schedule', exact: true }).click()
  await expect(editor.getByRole('button', { name: 'Saving…', exact: true })).toBeDisabled()
  await expect(editor.getByRole('button', { name: 'Cancel', exact: true })).toBeDisabled()
  await duplicateSubmit(editor)
  await expect(editor.getByRole('alert')).toContainText('Schedule was not saved')
  assert.equal(count(failingPath), savesBefore + 1, 'pending schedule save must block duplicates')
  await expect(editor.getByLabel('Edit schedule time for Living room')).toHaveValue('18:45')
  assert.deepEqual(state.rooms[0].schedules[0], initialSchedule, 'rejected edit must not alter the saved schedule')
  await editor.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(editor).toHaveCount(0)

  // Cancel discards the rejected draft and Edit starts from canonical fields.
  await page.getByRole('button', { name: 'Edit Apply scene at 21:15 in Living room', exact: true }).click()
  await expect(editor.getByLabel('Edit schedule time for Living room')).toHaveValue('21:15')
  await editor.getByLabel('Edit schedule time for Living room').fill('18:45')
  await editor.getByLabel('Edit schedule scene for Living room').selectOption('dawn')
  await editor.getByRole('button', { name: 'Sun', exact: true }).click()
  failingPath = delayedPath = null
  await editor.getByRole('button', { name: 'Save schedule', exact: true }).click()
  await expect(editor).toHaveCount(0)
  assert.deepEqual(state.rooms[0].schedules[0], { ...initialSchedule, hour: 18, minute: 45, weekdays: [1, 2, 4, 6], sceneID: 'dawn' })
  await expect(page.locator('.schedule-entry').getByText('Apply scene — Morning', { exact: true })).toBeVisible()

  // Missing scenes cannot be submitted, including an unchanged deleted scene.
  state.scenes = state.scenes.filter(scene => scene.id !== 'dawn')
  await expect(page.locator('.schedule-entry').getByText('Apply scene — missing scene', { exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Edit Apply scene at 18:45 in Living room', exact: true }).click()
  await expect(editor.getByRole('button', { name: 'Save schedule', exact: true })).toBeDisabled()
  await editor.getByLabel('Edit schedule action for Living room').selectOption('dim25')
  await editor.getByRole('button', { name: 'Save schedule', exact: true }).click()
  await expect(editor).toHaveCount(0)
  assert.equal(state.rooms[0].schedules[0].sceneID, null, 'non-scene actions must clear the saved scene')

  // Toggle and delete failures keep the saved state available for retry.
  failingPath = '/rooms/lounge/schedules/reading'
  const toggle = page.getByRole('checkbox', { name: 'Enable Dim to 25% at 18:45 in Living room', exact: true })
  await toggle.click()
  await expect(page.locator('.schedule-entry').getByRole('alert')).toContainText('Schedule was not changed')
  await expect(toggle).toBeChecked()
  failingPath = '/rooms/lounge/schedules/reading?delete=1'
  page.once('dialog', dialog => dialog.accept())
  await page.getByRole('button', { name: 'Delete Dim to 25% at 18:45 in Living room', exact: true }).click()
  await expect(page.locator('.schedule-entry').getByRole('alert')).toContainText('Schedule was not deleted')
  assert.equal(state.rooms[0].schedules.length, 1)
  failingPath = null
  await toggle.click()
  await expect(toggle).not.toBeChecked()

  // Creation retains all fields on failure and uses the same duplicate guard.
  const creator = page.getByRole('form', { name: 'Schedule for Living room', exact: true })
  await creator.getByLabel('Schedule time for Living room').fill('08:20')
  await creator.getByRole('button', { name: 'Sat', exact: true }).click()
  failingPath = delayedPath = '/rooms/lounge/schedules'
  const addsBefore = count(failingPath)
  await creator.getByRole('button', { name: 'Add schedule', exact: true }).click()
  await expect(creator.getByRole('button', { name: 'Adding…', exact: true })).toBeDisabled()
  await duplicateSubmit(creator)
  await expect(creator.getByRole('alert')).toContainText('Schedule was not added')
  assert.equal(count(failingPath), addsBefore + 1)
  await expect(creator.getByLabel('Schedule time for Living room')).toHaveValue('08:20')
  assert.deepEqual(await creator.locator('.day[aria-pressed=true]').allTextContents(), ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri'])
  failingPath = delayedPath = null
  await creator.getByRole('button', { name: 'Add schedule', exact: true }).click()
  await expect(page.locator('.schedule-entry')).toHaveCount(2)
  assert.deepEqual(state.rooms[0].schedules[1].weekdays, [1, 2, 3, 4, 5, 6])

  await page.setViewportSize({ width: 390, height: 844 })
  await noOverflow()
  const scheduleAxe = await new AxeBuilder({ page }).analyze()
  assert.deepEqual(scheduleAxe.violations.map(item => item.id), [], 'schedule controls must be accessible')
  await page.getByRole('button', { name: 'Devices', exact: true }).click()
  await page.getByLabel('Rename Desk lamp').fill('Another unsaved name')
  await noOverflow()
  const nameAxe = await new AxeBuilder({ page }).analyze()
  assert.deepEqual(nameAxe.violations.map(item => item.id), [], 'name controls must be accessible')
  assert.deepEqual(errors, [])
  console.log('SCHEDULE_NAME_ASSERTIONS_PASS: explicit rename, polling reconciliation, failed draft retention, cancel, prefilled schedule edits, weekday numbering, missing scenes, toggle/delete failure recovery, duplicate guards, narrow-screen overflow and accessibility')
} finally {
  await browser.close()
  server.kill()
}
