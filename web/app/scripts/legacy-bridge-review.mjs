// The published client must keep basic controls usable with a pre-/state bridge.
import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import assert from 'node:assert/strict'

const origin = 'http://127.0.0.1:4182'
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE } : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', '--host', '127.0.0.1', '--port', '4182', '--strictPort'], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 390, height: 844 } })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))
const device = { id: 'lifx:one', name: 'Reading lamp', brand: 'lifx', ip: '192.0.2.1', reachable: true,
  power: true, brightness: 65, color: { r: 255, g: 190, b: 100 }, kelvin: 3000 }
const commands = []
let modern = false
await page.route('**/*', async route => {
  const path = new URL(route.request().url()).pathname
  if (path === '/health') return route.fulfill({ json: { ok: true, service: 'lumendesk-bridge' } })
  if (path === '/state') return route.fulfill(modern
    ? { json: { devices: [device], rooms: [], scenes: [], favorites: [] } }
    : { status: 404, json: { error: 'Unknown route' } })
  if (path === '/devices') return route.fulfill({ json: { devices: [device] } })
  if (route.request().method() === 'POST' && path.startsWith('/devices/')) {
    const data = route.request().postDataJSON()
    commands.push({ path, data })
    if (path.endsWith('/power')) device.power = data.on
    else if (path.endsWith('/brightness')) device.brightness = data.value
    else return route.fulfill({ status: 404, json: { error: 'Unsupported route' } })
    return route.fulfill({ json: { device } })
  }
  return route.continue()
})

try {
  for (let attempt = 0; attempt < 80; attempt++) {
    try { await fetch(origin); break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  // A destination saved by a newer client must recover to basic lighting too.
  await context.addInitScript(() => localStorage.setItem('LumenDesk.destination.v1', 'music'))
  await page.goto(origin)
  await expect(page.getByText('This older bridge supports basic lighting controls.', { exact: false })).toBeVisible()
  await expect(page.getByRole('heading', { name: 'Fixtures', exact: true })).toBeVisible()
  await expect(page.locator('.room-setup')).toHaveCount(0)
  for (const name of ['Set up room', 'Scenes', 'Music', 'Schedules', 'Devices']) {
    await expect(page.getByRole('button', { name, exact: true })).toHaveCount(0)
  }
  await expect(page.getByText('Save current lighting', { exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: /Favorites/ })).toHaveCount(0)
  await expect(page.getByRole('button', { name: /Add .* to favorites/ })).toHaveCount(0)
  await page.getByRole('button', { name: 'Off', exact: true }).click()
  await expect.poll(() => device.power).toBe(false)
  await page.getByRole('slider', { name: /^Brightness/ }).fill('42')
  await expect.poll(() => device.brightness).toBe(42)
  assert.deepEqual(commands.map(command => command.path), ['/devices/lifx%3Aone/power', '/devices/lifx%3Aone/brightness'])
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false)
  assert.deepEqual((await new AxeBuilder({ page }).analyze()).violations.map(item => item.id), [])
  await page.getByRole('button', { name: 'Settings', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Settings', exact: true })).toBeVisible()
  assert.deepEqual(errors, [])

  // Upgrading the running bridge restores the complete setup flow without reload.
  modern = true
  await expect(page.locator('.room-setup').getByRole('heading', { name: 'Find lights', exact: true })).toBeVisible({ timeout: 10_000 })
  await expect(page.getByRole('button', { name: 'Devices', exact: true })).toBeVisible()
  await page.getByRole('button', { name: 'Room', exact: true }).click()
  await expect(page.getByRole('button', { name: 'Set up room', exact: true })).toBeVisible()
  console.log('LEGACY_BRIDGE_ASSERTIONS_PASS: compatibility fallback, basic lighting, saved destination recovery, unsupported actions hidden, phone layout, accessibility, upgrade without reload')
} finally {
  await browser.close()
  server.kill()
}
