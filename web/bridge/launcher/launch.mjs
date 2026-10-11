// Shared lifecycle used by the native launchers and Linux desktop shortcuts.
// This file runs with the bundled runtime; end users never need Node installed.
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import net from 'node:net'
import http from 'node:http'
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
let childClosed = null
let control = null
let stopping = false
let startupTimer = null
const requests = new AbortController()

const report = value => process.stdout.write(`${JSON.stringify(value)}\n`)

// One-shot loopback requests deliberately have no persistent HTTP agent. A
// launcher needs a bounded startup check, not a global browser fetch pool.
function request(address, timeoutMS = 2_000) {
  return new Promise((resolve, reject) => {
    let timer
    const req = http.get(address, { agent: false, signal: requests.signal }, res => {
      const chunks = []
      let bytes = 0
      res.on('data', chunk => {
        bytes += chunk.length
        if (bytes > 8 * 1024 * 1024) return req.destroy(new Error('The local bridge response is too large.'))
        chunks.push(chunk)
      })
      res.on('error', err => { clearTimeout(timer); reject(err) })
      res.once('close', () => {
        clearTimeout(timer)
        if (!res.complete) {
          const error = new Error('The local bridge closed an incomplete response.')
          error.code = 'ECONNRESET'
          reject(error)
        }
      })
      res.on('end', () => {
        clearTimeout(timer)
        const body = Buffer.concat(chunks).toString('utf8')
        resolve({
          ok: res.statusCode >= 200 && res.statusCode < 300,
          headers: { get: name => res.headers[name.toLowerCase()] },
          text: async () => body,
          json: async () => JSON.parse(body),
        })
      })
    })
    timer = setTimeout(() => {
      const error = new Error('The local bridge did not answer in time.')
      error.name = 'TimeoutError'
      req.destroy(error)
    }, timeoutMS)
    req.on('error', err => { clearTimeout(timer); reject(err) })
  })
}

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
  process.exitCode = exitCode
  clearTimeout(startupTimer)
  requests.abort()
  process.stdin.destroy()
  if (control) {
    control.close()
    await fs.rm(socketFile, { force: true }).catch(() => {})
  }
  if (child) {
    // 'close' follows 'exit' only after the child stdout/stderr pipes drain.
    // Forcing process.exit while Windows closes those handles can crash libuv.
    let killTimer
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM')
      killTimer = setTimeout(() => {
        if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
      }, 2_000)
    }
    await childClosed
    clearTimeout(killTimer)
  }
  // Let the loop drain pending pipe/file callbacks instead of tearing down
  // native handles underneath them. All launcher-owned deadlines are cleared.
}

async function existingBridge() {
  try {
    const response = await request(`${url}/health`, 750)
    const health = await response.json()
    if (!response.ok || health.service !== 'lumendesk-bridge' || health.ok !== true) {
      throw new Error(`Port ${port} is already in use by another application. Close that application, then reopen LumenDesk Bridge.`)
    }
    const page = await request(url, 750)
    if (!page.ok || !page.headers.get('content-type')?.startsWith('text/html')) {
      throw new Error('A developer bridge is already running without the web app. Quit that bridge, then reopen LumenDesk Bridge.')
    }
    return true
  } catch (err) {
    if (err.code === 'ECONNREFUSED') return false
    // Timeouts and an occupied non-HTTP port need a useful error, not a second
    // process fighting for the same sockets.
    if (err.name === 'TimeoutError' || err.name === 'SyntaxError' || err.code === 'ECONNRESET') {
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
  if (stopping) return
  if (desktop) {
    const opened = await requestControl('open')
    if (stopping || opened) return
  }
  const existing = !smoke && port !== 0 && await existingBridge()
  if (stopping) return
  if (existing) {
    report({ event: 'ready', url, owned: false })
    if (desktop) openBrowser(url)
    return shutdown()
  }

  const args = [path.join(root, 'web', 'bridge', 'src', 'index.js'), '--quiet', '--port', String(port)]
  if (smoke) args.push('--no-network', '--port', '0')
  child = spawn(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
  childClosed = new Promise(resolve => child.once('close', resolve))
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
  let address
  try {
    address = await Promise.race([
      ready,
      new Promise((_, reject) => {
        startupTimer = setTimeout(() => reject(new Error('LumenDesk did not finish starting. Check whether another lighting app is using the local network ports.')), 15_000)
      }),
    ])
  } finally { clearTimeout(startupTimer) }
  if (stopping) return
  const health = await (await request(`${address}/health`)).json()
  if (stopping) return
  if (health.service !== 'lumendesk-bridge' || !health.ok) throw new Error('The local bridge did not pass its startup check.')
  report({ event: 'ready', url: address, owned: true })

  if (smoke) {
    const page = await request(address)
    const html = await page.text()
    if (!page.ok || !html.includes('type="module"')) throw new Error('The bundled web app is missing its module entry.')
    const assets = [...html.matchAll(/(?:src|href)="([^"\s]+\.(?:js|css))"/g)].map(match => match[1])
    if (!assets.length) throw new Error('No bundled web assets found.')
    for (const asset of assets) {
      const response = await request(new URL(asset, address))
      if (!response.ok || !(await response.text()).length) throw new Error(`Bundled asset did not load: ${asset}`)
    }
    const state = await (await request(`${address}/state`)).json()
    if (stopping) return
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
    if (stopping) return
    await fs.rm(socketFile, { force: true })
    if (stopping) return
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
    if (stopping) return
    await fs.chmod(socketFile, 0o600)
    if (stopping) return
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
  if (stopping) return
  report({ event: 'error', message: err.message })
  console.error(err.message)
  await shutdown(1)
})
