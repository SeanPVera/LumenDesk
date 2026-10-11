// Shared lifecycle used by the native launchers and Linux desktop shortcuts.
// This file runs with the bundled runtime; end users never need Node installed.
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import net from 'node:net'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const smoke = process.argv.includes('--smoke-test')
const desktop = process.argv.includes('--desktop')
const stopRequested = process.argv.includes('--stop')
const portOption = process.argv.indexOf('--port')
const port = portOption === -1 ? 8765 : Number(process.argv[portOption + 1])
if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('--port must be between 0 and 65535.')
const url = `http://127.0.0.1:${port}`
const directory = path.join(os.homedir(), '.lumendesk')
const socketFile = path.join(directory, 'launcher.sock')
let child = null
let control = null
let stopping = false

const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const report = value => process.stdout.write(`${JSON.stringify(value)}\n`)

function openBrowser(address) {
  const command = process.platform === 'darwin' ? 'open' : 'xdg-open'
  const browser = spawn(command, [address], { stdio: 'ignore' })
  browser.on('error', () => console.error(`Open ${address} in your browser.`))
  browser.unref()
}

async function requestControl(command) {
  // Only the Linux desktop wrapper uses this user-private Unix socket.
  return new Promise(resolve => {
    const socket = net.createConnection(socketFile)
    let response = ''
    socket.setTimeout(1_500, () => socket.destroy())
    socket.on('connect', () => socket.end(`${command}\n`))
    socket.on('data', data => { response += data })
    socket.on('error', () => resolve(false))
    socket.on('close', () => resolve(response.trim() === 'ok'))
  })
}

async function shutdown(exitCode = 0) {
  if (stopping) return
  stopping = true
  if (control) {
    control.close()
    await fs.rm(socketFile, { force: true }).catch(() => {})
  }
  if (child && child.exitCode === null && child.signalCode === null) {
    child.kill('SIGTERM')
    await Promise.race([
      new Promise(resolve => child.once('exit', resolve)),
      delay(2_000),
    ])
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
  }
  process.exit(exitCode)
}

async function existingBridge() {
  try {
    const response = await fetch(`${url}/health`, { signal: AbortSignal.timeout(750) })
    const health = await response.json()
    if (!response.ok || health.service !== 'lumendesk-bridge' || health.ok !== true) {
      throw new Error(`Port ${port} is already in use by another application. Close that application, then reopen LumenDesk Bridge.`)
    }
    const page = await fetch(url, { signal: AbortSignal.timeout(750) })
    if (!page.ok || !page.headers.get('content-type')?.startsWith('text/html')) {
      throw new Error('A developer bridge is already running without the web app. Quit that bridge, then reopen LumenDesk Bridge.')
    }
    return true
  } catch (err) {
    if (err.name === 'TypeError' && err.cause?.code === 'ECONNREFUSED') return false
    // Timeouts and an occupied non-HTTP port need a useful error, not a second
    // process fighting for the same sockets.
    if (err.name === 'TimeoutError' || err.name === 'SyntaxError') {
      throw new Error(`Port ${port} did not answer as LumenDesk. Close the application using it, then reopen LumenDesk Bridge.`)
    }
    throw err
  }
}

async function start() {
  if (stopRequested) {
    if (!await requestControl('stop')) throw new Error('No desktop LumenDesk Bridge is running.')
    return
  }
  await fs.access(path.join(root, 'web', 'app', 'dist', 'index.html'))
  if (desktop && await requestControl('open')) return
  if (!smoke && port !== 0 && await existingBridge()) {
    report({ event: 'ready', url, owned: false })
    if (desktop) openBrowser(url)
    return shutdown()
  }

  const args = [path.join(root, 'web', 'bridge', 'src', 'index.js'), '--quiet', '--port', String(port)]
  if (smoke) args.push('--no-network', '--port', '0')
  child = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
  let startupText = ''
  const ready = new Promise((resolve, reject) => {
    child.on('error', reject)
    child.on('exit', code => {
      if (!stopping) reject(new Error(`LumenDesk could not start (exit ${code}). ${startupText.trim().slice(-1_000)}`))
    })
    child.stdout.on('data', data => {
      startupText = (startupText + data).slice(-8_192)
      const match = startupText.match(/Open (http:\/\/127\.0\.0\.1:\d+)/)
      if (match) resolve(match[1])
      process.stderr.write(data)
    })
    child.stderr.on('data', data => {
      startupText = (startupText + data).slice(-8_192)
      process.stderr.write(data)
    })
  })
  const address = await Promise.race([
    ready,
    delay(15_000).then(() => { throw new Error('LumenDesk did not finish starting. Check whether another lighting app is using the local network ports.') }),
  ])
  const health = await (await fetch(`${address}/health`)).json()
  if (health.service !== 'lumendesk-bridge' || !health.ok) throw new Error('The local bridge did not pass its startup check.')
  report({ event: 'ready', url: address, owned: true })

  if (smoke) {
    const page = await fetch(address)
    const html = await page.text()
    if (!page.ok || !html.includes('type="module"')) throw new Error('The bundled web app is missing its module entry.')
    const assets = [...html.matchAll(/(?:src|href)="([^"\s]+\.(?:js|css))"/g)].map(match => match[1])
    if (!assets.length) throw new Error('No bundled web assets found.')
    for (const asset of assets) {
      const response = await fetch(new URL(asset, address))
      if (!response.ok || !(await response.text()).length) throw new Error(`Bundled asset did not load: ${asset}`)
    }
    const state = await (await fetch(`${address}/state`)).json()
    if (!Array.isArray(state.devices) || state.devices.length) throw new Error('Smoke mode should have no device connections.')
    report({ event: 'smoke-passed', version: health.version, assets: assets.length })
    return shutdown()
  }

  child.once('exit', code => {
    if (!stopping) {
      report({ event: 'error', message: `The bridge stopped unexpectedly (exit ${code}). Reopen LumenDesk Bridge to reconnect.` })
      shutdown(1)
    }
  })
  if (desktop) {
    await fs.mkdir(directory, { recursive: true, mode: 0o700 })
    await fs.rm(socketFile, { force: true })
    control = net.createServer(socket => {
      let received = ''
      socket.setTimeout(1_000, () => socket.destroy())
      socket.on('data', data => {
        received += data
        if (received.length > 32) return socket.destroy()
        if (!received.includes('\n')) return
        const command = received.trim()
        if (command === 'open') openBrowser(address)
        socket.end(command === 'open' || command === 'stop' ? 'ok\n' : 'unknown\n')
        if (command === 'stop') socket.once('close', () => shutdown())
      })
    })
    await new Promise((resolve, reject) => {
      control.once('error', reject)
      control.listen(socketFile, resolve)
    })
    await fs.chmod(socketFile, 0o600)
    openBrowser(address)
  }
}

process.on('SIGINT', () => shutdown())
process.on('SIGTERM', () => shutdown())
// Native windows can be closed while network sockets are still starting.
// Listen before the first startup await so Quit never waits for readiness.
if (!desktop && !smoke && !stopRequested) {
  let input = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', data => {
    input += data
    if (input.length > 64) return shutdown(1)
    if (input.trim() === 'quit') shutdown()
  })
  // If the native wrapper exits, don't leave an orphaned lighting process.
  process.stdin.on('end', () => shutdown())
  process.stdin.resume()
}
start().catch(async err => {
  report({ event: 'error', message: err.message })
  console.error(err.message)
  await shutdown(1)
})
