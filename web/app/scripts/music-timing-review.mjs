// Run the production file player, beat mapping and timing controls in Chromium.
import { chromium, expect } from '@playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { spawn } from 'node:child_process'
import { mkdir, readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'

const origin = 'http://127.0.0.1:4182'
const html = await readFile(new URL('../dist/index.html', import.meta.url), 'utf8')
const source = html.match(/<script\b[^>]*\btype=["']module["'][^>]*>/)?.[0]?.match(/\bsrc=["']([^"']+)["']/)?.[1]
assert.ok(source, 'Build the app first')
const assets = new URL(source, origin).pathname
const base = assets.slice(0, assets.lastIndexOf('/assets/') + 1)
const output = process.env.LUMENDESK_WEB_QA_DIRECTORY ?? '/tmp/LumenDesk-Web-QA'
await mkdir(output, { recursive: true })
const browser = await chromium.launch(process.env.LUMENDESK_CHROMIUM_EXECUTABLE
  ? { executablePath: process.env.LUMENDESK_CHROMIUM_EXECUTABLE } : {})
const server = spawn(process.execPath, ['node_modules/vite/bin/vite.js', 'preview', '--host', '127.0.0.1', '--port', '4182', '--strictPort', '--base', base], { stdio: 'pipe' })
const context = await browser.newContext({ viewport: { width: 1100, height: 900 } })
const page = await context.newPage()
const errors = []
page.on('pageerror', error => errors.push(error.message))
await context.addInitScript(() => {
  const NativeAudioContext = window.AudioContext
  window.AudioContext = class extends NativeAudioContext {
    constructor(...args) { super(...args); window.musicReviewAudio = this }
  }
})
const device = { id: 'lifx:one', name: 'Reading lamp', brand: 'lifx', ip: '192.0.2.1', reachable: true,
  power: true, brightness: 65, color: { r: 255, g: 190, b: 100 }, kelvin: 3000, controlRevision: 7 }
const frames = []
await page.route('**/*', async route => {
  const path = new URL(route.request().url()).pathname
  if (path === '/health') return route.fulfill({ json: { ok: true, service: 'lumendesk-bridge' } })
  if (path === '/state') return route.fulfill({ json: { devices: [device], rooms: [], scenes: [], favorites: [] } })
  if (path === '/music/frame') {
    frames.push(route.request().postDataJSON().states)
    return route.fulfill({ json: { ok: true, applied: 1, stage: 'accepted-for-local-dispatch' } })
  }
  return route.continue()
})

// A real mono WAV with two silent seconds, then 120 BPM kicks for 18 seconds.
const rate = 44100, samples = rate * 20
const wav = Buffer.alloc(44 + samples * 2)
wav.write('RIFF', 0); wav.writeUInt32LE(wav.length - 8, 4); wav.write('WAVEfmt ', 8)
wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22)
wav.writeUInt32LE(rate, 24); wav.writeUInt32LE(rate * 2, 28)
wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34); wav.write('data', 36); wav.writeUInt32LE(samples * 2, 40)
for (let beat = 0; 2.1 + beat * 0.5 < 20; beat++) {
  const start = Math.round((2.1 + beat * 0.5) * rate)
  for (let i = 0; i < rate * 0.08 && start + i < samples; i++) {
    const sample = (beat % 4 === 0 ? 0.9 : 0.5) * Math.sin(2 * Math.PI * 60 * i / rate) * Math.exp(-i / (rate * 0.03))
    wav.writeInt16LE(Math.round(sample * 32767), 44 + (start + i) * 2)
  }
}

try {
  for (let attempt = 0; attempt < 80; attempt++) {
    try { await fetch(`${origin}${base}`); break } catch { await new Promise(resolve => setTimeout(resolve, 100)) }
  }
  await page.goto(`${origin}${base}`)
  await page.getByRole('button', { name: 'Music', exact: true }).click()
  const music = page.locator('.music-desk')
  await music.getByRole('button', { name: 'Audio file', exact: true }).click()
  await music.getByLabel('Choose audio file', { exact: true }).setInputFiles({ name: 'steady-kicks.wav', mimeType: 'audio/wav', buffer: wav })
  assert.equal(await page.evaluate(() => Boolean(window.musicReviewAudio)), false, 'choosing a file must not start audio')
  await expect(music.getByText('Default timing (0 ms)', { exact: true })).toBeVisible()
  await music.getByRole('button', { name: 'Start', exact: true }).click()
  await expect(music.getByText(/Beat map ready/)).toBeVisible()
  await expect(music.getByText(/Listening live outside the mapped beats/)).toBeVisible()
  await expect(music.getByRole('button', { name: 'Tap with the lights', exact: true })).toBeEnabled({ timeout: 10000 })
  const tap = music.getByRole('button', { name: 'Tap with the lights', exact: true })
  await tap.click({ clickCount: 8, delay: 10 })
  await expect(music.getByRole('button', { name: 'Use measured timing', exact: true })).toBeDisabled()

  await page.evaluate(() => window.musicReviewAudio.suspend())
  await expect(music.getByRole('button', { name: 'Resume audio', exact: true })).toBeVisible()
  await expect(tap).toBeDisabled()
  await page.screenshot({ path: `${output}/music-audio-paused.png`, fullPage: true })
  await music.getByRole('button', { name: 'Resume audio', exact: true }).click()
  await expect(music.getByRole('button', { name: 'Resume audio', exact: true })).toHaveCount(0)
  await expect(tap).toBeEnabled({ timeout: 10000 })

  for (const width of [1100, 390]) {
    await page.setViewportSize({ width, height: 900 })
    await page.screenshot({ path: `${output}/music-file-timing-${width}.png`, fullPage: true })
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `horizontal overflow at ${width}px`)
    const results = await new AxeBuilder({ page }).analyze()
    assert.deepEqual(results.violations.filter(item => ['critical', 'serious'].includes(item.impact))
      .map(item => ({ id: item.id, nodes: item.nodes.map(node => node.target) })), [])
  }
  await music.getByRole('button', { name: 'Stop', exact: true }).click()
  await expect(tap).toBeDisabled()
  await expect(music.getByRole('button', { name: 'Use measured timing', exact: true })).toBeDisabled()
  await expect.poll(() => frames.some(states => states.some(state => state.restoring))).toBe(true)
  await expect.poll(() => music.locator('.fixture-swatch').evaluate(element => element.style.backgroundColor)).toBe('')
  assert.deepEqual(errors, [])
  console.log('PASS: real file mapping, silent intro, calibration, audio resume, Stop, mobile layout and axe checks')
} finally {
  await browser.close()
  server.kill()
}
