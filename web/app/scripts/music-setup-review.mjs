// Exercise the production App's Music setup and restoration lifecycle. Run
// from web/app after npm run build and installing the visual-review dependencies.
import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'

const port = 4178
const origin = `http://127.0.0.1:${port}`
// Pages builds carry their deployment path in the bundle. Preview that same
// path even when BASE_PATH is absent from the later review job's environment.
const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8')
const moduleTag = html.match(/<script\b[^>]*\btype=["']module["'][^>]*>/)?.[0]
const moduleSource = moduleTag?.match(/\bsrc=["']([^"']+)["']/)?.[1]
assert.ok(moduleSource, 'Build the production app before running the Music review')
const modulePath = new URL(moduleSource, origin).pathname
const assetsIndex = modulePath.lastIndexOf('/assets/')
assert.ok(assetsIndex >= 0, 'The built app must reference its bundled module in assets')
const base = modulePath.slice(0, assetsIndex + 1)
const appURL = `${origin}${base}`
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE }
  : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', String(port), '--strictPort', '--base', base], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 1100, height: 900 } })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))

// Capture failures are deterministic, while the real session, renderer and App
// still handle Start/Restart/Stop, room scope, frame dispatch and restoration.
await context.addInitScript(() => {
  window.musicCaptureRequests = { microphone: 0, midi: 0, file: 0 }
  window.AudioContext = class {
    audioWorklet = { addModule: async () => undefined }
    close() { return Promise.resolve() }
    decodeAudioData() {
      window.musicCaptureRequests.file++
      return Promise.reject(new Error('Audio file could not be decoded.'))
    }
  }
  Object.defineProperty(navigator.mediaDevices, 'getUserMedia', { value: async () => {
    window.musicCaptureRequests.microphone++
    throw new DOMException('Microphone access denied.', 'NotAllowedError')
  } })
  Object.defineProperty(navigator, 'requestMIDIAccess', { value: async () => {
    window.musicCaptureRequests.midi++
    throw new DOMException('MIDI access denied.', 'NotAllowedError')
  } })
})

const devices = [
  { id: 'lifx:lounge', name: 'Reading lamp', brand: 'lifx', ip: '192.0.2.1', reachable: true, power: true,
    brightness: 65, color: { r: 255, g: 190, b: 100 }, kelvin: 3000, roomID: 'lounge', controlRevision: 7 },
  { id: 'lifx:office', name: 'Desk lamp', brand: 'lifx', ip: '192.0.2.2', reachable: true, power: false,
    brightness: 40, color: { r: 100, g: 180, b: 255 }, kelvin: 4000, roomID: 'office', controlRevision: 11 },
]
const original = structuredClone(devices)
const state = {
  devices, scenes: [], favorites: [],
  rooms: devices.map(device => ({ id: device.roomID, name: device.roomID === 'lounge' ? 'Living room' : 'Office', lightIDs: [device.id], schedules: [] })),
}
const frames = []
const badRevisions = []
let refuseRestore = false
await page.route('**/*', async route => {
  const path = new URL(route.request().url()).pathname
  if (!['/health', '/state', '/music/frame'].includes(path)) return route.continue()
  if (path === '/health') return route.fulfill({ json: { ok: true, service: 'lumendesk-bridge' } })
  if (path === '/state') return route.fulfill({ json: state })
  const commands = route.request().postDataJSON().states
  frames.push(structuredClone(commands))
  if (refuseRestore && commands.some(command => command.restoring)) {
    return route.fulfill({ status: 503, json: { error: 'Starting light output could not be sent.' } })
  }
  for (const command of commands) {
    const device = devices.find(candidate => candidate.id === command.fixtureID)
    if (command.controlRevision !== device?.controlRevision) badRevisions.push(command)
    if (device) Object.assign(device, { color: command.rgb, brightness: command.brightness * 100 })
  }
  return route.fulfill({ json: { ok: true, applied: commands.length, stage: 'accepted-for-local-dispatch' } })
})

const liveFrames = () => frames.filter(commands => commands.some(command => !command.restoring && !command.release))
const restores = () => frames.filter(commands => commands.some(command => command.restoring))
const requests = () => page.evaluate(() => window.musicCaptureRequests)
const music = page.locator('.music-desk')
const controlRoom = page.getByLabel('Control room')
const expectRoom = async (roomID, name) => {
  await controlRoom.selectOption(roomID)
  await expect(music.getByLabel(`Role for ${name}`, { exact: true })).toBeVisible()
  await expect(music.locator('.fixture-list li')).toHaveCount(1)
  await expect(music.getByText('1 included light · 0 left out', { exact: true })).toBeVisible()
}

try {
  for (let attempt = 0; attempt < 80; attempt++) {
    try { await fetch(appURL); break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  await page.goto(appURL)
  await controlRoom.selectOption('lounge')
  await page.getByRole('button', { name: 'Music', exact: true }).click()
  await expect(music.getByLabel('Role for Reading lamp', { exact: true })).toBeVisible()

  // Denied permissions and an unreadable file must leave setup usable. Changing
  // rooms and returning must repopulate targets without an intervening Stop.
  for (const source of [
    { name: 'Microphone', error: 'Microphone access denied.' },
    { name: 'MIDI clock', error: 'MIDI access denied.' },
    { name: 'Audio file', error: 'Audio file could not be decoded.' },
  ]) {
    const before = await requests()
    await music.getByRole('button', { name: source.name, exact: true }).click()
    if (source.name === 'Audio file') await music.getByLabel('Choose audio file', { exact: true }).setInputFiles({
      name: 'unreadable.wav', mimeType: 'audio/wav', buffer: Buffer.from('unreadable audio'),
    })
    assert.deepEqual(await requests(), before, 'selecting a source/file must not capture audio')
    await music.getByRole('button', { name: 'Start', exact: true }).click()
    await expect(music.getByRole('alert')).toContainText(source.error)
    await expect(controlRoom).toBeEnabled()
    await expect(music.getByRole('button', { name: 'Start', exact: true })).toBeEnabled()
    assert.equal(liveFrames().length, 0, 'failed initial capture must not dispatch music frames')
    await expectRoom('office', 'Desk lamp')
    await expectRoom('lounge', 'Reading lamp')
  }
  assert.deepEqual(await requests(), { microphone: 1, midi: 1, file: 1 })

  // Start the real demo renderer, then deny a source Restart. The original
  // lighting remains the restoration baseline, even after idle room changes.
  await music.getByRole('button', { name: 'Demo groove', exact: true }).click()
  await music.getByRole('button', { name: 'Start', exact: true }).click()
  await expect.poll(() => liveFrames().length).toBeGreaterThan(0)
  await expect(controlRoom).toBeDisabled()
  const beforeMicrophone = (await requests()).microphone
  await music.getByRole('button', { name: 'Microphone', exact: true }).click()
  await expect(music.getByText(/Selected for the next start: Microphone/)).toBeVisible()
  assert.equal((await requests()).microphone, beforeMicrophone)
  await expect(music.locator('.music-transport')).toContainText('Running · Demo groove')
  const beforeFailedRestart = restores().length
  await music.getByRole('button', { name: 'Restart', exact: true }).click()
  await expect(music.getByRole('alert')).toContainText('Microphone access denied.')
  await expect.poll(() => restores().length).toBe(beforeFailedRestart + 1)
  const rolledBack = restores().at(-1)
  assert.equal(rolledBack.length, 1)
  assert.deepEqual(rolledBack[0].rgb, original[0].color, 'failed Restart automatically restores the first show’s baseline')
  assert.equal(rolledBack[0].brightness, original[0].brightness / 100)
  await expect(controlRoom).toBeEnabled()
  await expectRoom('office', 'Desk lamp')
  await expectRoom('lounge', 'Reading lamp')
  await expectRoom('office', 'Desk lamp')
  await expect(music.getByText(/Turn it on in Room before starting/)).toBeVisible()

  // A later explicit Start captures the new room's revisions. Recovering the
  // fixture list alone is insufficient: the bridge must accept its frames.
  const beforeOffice = liveFrames().length
  await music.getByRole('button', { name: 'Demo groove', exact: true }).click()
  await music.getByRole('button', { name: 'Start', exact: true }).click()
  await expect.poll(() => liveFrames().slice(beforeOffice).some(commands => commands.some(command => command.fixtureID === 'lifx:office'))).toBe(true)
  assert.deepEqual(badRevisions, [], 'each included fixture needs its own captured control revision')
  const beforeOfficeStop = restores().length
  await music.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect.poll(() => restores().length).toBe(beforeOfficeStop + 1)
  const restored = restores().at(-1)
  assert.equal(restored.length, 1, 'a new show snapshots only its selected room')
  assert.equal(restored[0].fixtureID, original[1].id)
  assert.deepEqual(restored[0].rgb, original[1].color)
  assert.equal(restored[0].brightness, original[1].brightness / 100)
  assert.equal(restored[0].controlRevision, original[1].controlRevision)

  // Failed restoration still gates a new show and its permission request,
  // while idle room selection remains usable. Retry must unblock Start.
  await expectRoom('lounge', 'Reading lamp')
  await music.getByRole('button', { name: 'Start', exact: true }).click()
  await expect(music.locator('.music-transport')).toContainText('Running · Demo groove')
  refuseRestore = true
  await music.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect(music.getByRole('alert')).toContainText('Starting light output could not be sent.')
  await expectRoom('office', 'Desk lamp')
  const beforeBlocked = liveFrames().length
  const beforeRequests = await requests()
  await music.getByRole('button', { name: 'Microphone', exact: true }).click()
  await music.getByRole('button', { name: 'Start', exact: true }).click()
  await expect(music.getByRole('button', { name: 'Start', exact: true })).toBeEnabled()
  assert.deepEqual(await requests(), beforeRequests, 'pending restoration must finish before another capture starts')
  assert.equal(liveFrames().length, beforeBlocked, 'pending restoration must block another show')
  refuseRestore = false
  await music.getByRole('button', { name: 'Retry now', exact: true }).click()
  await expect(music.getByRole('button', { name: 'Retry now', exact: true })).toHaveCount(0)
  await music.getByRole('button', { name: 'Demo groove', exact: true }).click()
  await music.getByRole('button', { name: 'Start', exact: true }).click()
  await expect.poll(() => liveFrames().length).toBeGreaterThan(beforeBlocked)
  await music.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect(controlRoom).toBeEnabled()

  await page.setViewportSize({ width: 390, height: 844 })
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1), false)
  const axe = await new AxeBuilder({ page }).analyze()
  assert.deepEqual(axe.violations.map(violation => violation.id), [], 'Music setup must be accessible')
  assert.deepEqual(errors, [])
  assert.deepEqual(badRevisions, [])
  console.log('MUSIC_SETUP_ASSERTIONS_PASS: explicit capture, microphone/MIDI/file failure recovery, room changes without Stop, failed Restart baseline preservation, new-room control revisions, pending restoration gating, narrow-screen overflow and accessibility')
} finally {
  await browser.close()
  server.kill()
}
