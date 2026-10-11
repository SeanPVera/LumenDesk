#!/usr/bin/env node
// Verify and exercise the actual distributable, not the working source tree.
import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import { spawn } from 'node:child_process'

const bundle = path.resolve(process.argv[2] || '')
if (!process.argv[2]) throw new Error('Usage: node scripts/smoke_bridge_package.mjs path/to/package')
const work = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-smoke with spaces-'))
const sha256 = async file => crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex')
const psQuote = value => `'${value.replaceAll("'", "''")}'`
function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const { captureStderr = false, ...spawnOptions } = options
    const child = spawn(command, args, { stdio: captureStderr ? ['inherit', 'inherit', 'pipe'] : 'inherit', ...spawnOptions })
    let stderr = ''
    child.stderr?.on('data', data => {
      stderr = (stderr + data).slice(-8_192)
      process.stderr.write(data)
    })
    const timeout = setTimeout(() => { child.kill(); reject(new Error(`${command} timed out`)) }, 40_000)
    child.on('error', err => { clearTimeout(timeout); reject(err) })
    child.on('close', code => {
      clearTimeout(timeout)
      if (code === 0) return resolve()
      const error = new Error(`${command} exited with ${code}`)
      error.stderr = stderr
      reject(error)
    })
  })
}

async function attachDiskImage(root) {
  // DiskImages can briefly hold its device after creating a fresh image.
  // Retry only its explicit temporary-resource error; invalid images and
  // every launcher/hash failure retain their normal immediate failure.
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    try {
      await run('hdiutil', ['attach', '-readonly', '-nobrowse', '-mountpoint', root, bundle], { captureStderr: true })
      return
    } catch (err) {
      if (attempt === 4 || err.stderr?.trim() !== 'hdiutil: attach failed - Resource temporarily unavailable') throw err
      console.error(`DiskImages device is still releasing; retrying attachment (${attempt + 1}/4).`)
      await new Promise(resolve => setTimeout(resolve, 1_000))
    }
  }
}

let mounted = false
try {
  const expected = (await fs.readFile(`${bundle}.sha256`, 'utf8')).trim().split(/\s+/)[0]
  if (await sha256(bundle) !== expected) throw new Error('Package SHA256 did not match its checksum file.')
  let root
  if (process.platform === 'darwin') {
    root = path.join(work, 'mount')
    await fs.mkdir(root)
    await attachDiskImage(root)
    mounted = true
    await run('codesign', ['--verify', '--deep', '--strict', path.join(root, 'LumenDesk Bridge.app')])
  } else {
    if (process.platform === 'win32') await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `$ErrorActionPreference = 'Stop'; Expand-Archive -LiteralPath ${psQuote(bundle)} -DestinationPath ${psQuote(work)}`])
    else await run('tar', ['-xzf', bundle, '-C', work])
    root = path.join(work, (await fs.readdir(work))[0])
  }
  const manifest = JSON.parse(await fs.readFile(path.join(root, 'BUILD-MANIFEST.json'), 'utf8'))
  if (manifest.platform !== process.platform || manifest.arch !== process.arch) throw new Error('Smoke test requires the same OS and CPU as the package.')
  for (const [name, digest] of Object.entries(manifest.files)) {
    const target = path.resolve(root, name)
    if (!target.startsWith(root + path.sep)) throw new Error(`Invalid manifest path ${name}`)
    if (await sha256(target) !== digest) throw new Error(`Shipped file SHA256 mismatch: ${name}`)
  }
  // Use an isolated HOME so the smoke test neither reads the reviewer's saved
  // state nor loads Nanoleaf credentials. --no-network also leaves all vendor
  // sockets closed; the only traffic here is the loopback HTTP smoke check.
  const home = path.join(work, 'test-home')
  await fs.mkdir(home)
  const env = { ...process.env, HOME: home, USERPROFILE: home }
  if (process.platform === 'darwin') {
    await run(path.join(root, 'LumenDesk Bridge.app', 'Contents', 'MacOS', 'LumenDesk Bridge'), ['--smoke-test'], { env })
  } else if (process.platform === 'win32') {
    // Exercise repeated start/stop because the Windows pipe-teardown defect
    // was intermittent. Every iteration must pass; failures are not retried.
    for (let iteration = 1; iteration <= 3; iteration += 1) {
      const resultFile = path.join(root, 'smoke-result.jsonl')
      await fs.rm(resultFile, { force: true })
      let failure = null
      try {
        await run(path.join(root, 'LumenDesk Bridge.exe'), ['--smoke-test'], { env })
      } catch (err) { failure = err }
      // The GUI executable captures its Node child's stdout/stderr in a file.
      // Print it even on failure, before cleanup removes the extracted bundle.
      const result = await fs.readFile(resultFile, 'utf8').catch(() => '')
      console.log(`Windows native launcher start/stop ${iteration}/3`)
      if (result) process.stdout.write(result)
      if (failure) throw failure
      if (!result.includes('"event":"smoke-passed"')) throw new Error('Native Windows launcher did not report a completed smoke test.')
    }
  } else await run(path.join(root, 'Start LumenDesk.sh'), ['--smoke-test'], { env })
  console.log(`Verified ${Object.keys(manifest.files).length} packaged files and native launcher startup, static assets, state API and shutdown.`)
} finally {
  if (mounted) await run('hdiutil', ['detach', path.join(work, 'mount')])
  await fs.rm(work, { recursive: true, force: true })
}
