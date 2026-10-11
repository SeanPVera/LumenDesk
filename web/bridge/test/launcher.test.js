import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import http from 'node:http'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { fileURLToPath } from 'node:url'

const launcher = fileURLToPath(new URL('../launcher/launch.mjs', import.meta.url))

// A loopback-only stand-in lets lifecycle tests exercise packaging startup
// without starting vendor sockets or any real discovery traffic. The shipped
// package smoke test separately exercises the actual bridge and React build.
const stub = `import http from 'node:http';
const at = process.argv.indexOf('--port');
const server = http.createServer((req, res) => {
  if (req.url === '/') { res.setHeader('Content-Type', 'text/html'); res.end('<html></html>'); }
  else { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ ok: true, service: 'lumendesk-bridge', version: 'test' })); }
});
server.listen(Number(process.argv[at + 1]), '127.0.0.1', () => {
  console.error('child-pid:' + process.pid);
  console.log('LumenDesk is running. Open http://127.0.0.1:' + server.address().port);
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk launcher spaces-'))
  await fs.mkdir(path.join(root, 'launcher'), { recursive: true })
  await fs.mkdir(path.join(root, 'web', 'app', 'dist'), { recursive: true })
  await fs.mkdir(path.join(root, 'web', 'bridge', 'src'), { recursive: true })
  await fs.copyFile(launcher, path.join(root, 'launcher', 'launch.mjs'))
  await fs.writeFile(path.join(root, 'web', 'app', 'dist', 'index.html'), '<html></html>')
  await fs.writeFile(path.join(root, 'web', 'bridge', 'package.json'), '{"type":"module"}')
  await fs.writeFile(path.join(root, 'web', 'bridge', 'src', 'index.js'), stub)
  t.after(() => fs.rm(root, { recursive: true, force: true }))
  return root
}

function start(root, port = 0, extra = [], overrides = {}) {
  const child = spawn(process.execPath, [path.join(root, 'launcher', 'launch.mjs'), '--port', String(port), ...extra], {
    env: { ...process.env, HOME: root, USERPROFILE: root },
    stdio: ['pipe', 'pipe', 'pipe'],
    ...overrides,
  })
  let output = '', errors = ''
  child.stdout.on('data', data => { output += data })
  child.stderr.on('data', data => { errors += data })
  const exited = once(child, 'exit')
  const event = type => new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { cleanup(); reject(new Error(`No ${type} event: ${output} ${errors}`)) }, 5_000)
    const check = () => {
      for (const line of output.trim().split('\n')) {
        let item
        try { item = JSON.parse(line) } catch { continue }
        if (item.event === type) { cleanup(); resolve(item); return }
      }
    }
    const cleanup = () => { clearTimeout(timeout); child.stdout.off('data', check) }
    child.stdout.on('data', check)
    check()
  })
  const stderrMatch = pattern => new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { cleanup(); reject(new Error(`No ${pattern} marker: ${errors}`)) }, 5_000)
    const check = () => {
      const match = errors.match(pattern)
      if (match) { cleanup(); resolve(match) }
    }
    const cleanup = () => { clearTimeout(timeout); child.stderr.off('data', check) }
    child.stderr.on('data', check)
    check()
  })
  const childStarted = async () => Number((await stderrMatch(/child-pid:(\d+)/))[1])
  return { child, exited, event, childStarted, stderrMatch, output: () => output, childPID: () => Number(errors.match(/child-pid:(\d+)/)?.[1]) }
}

async function exitBeforeFallback(run) {
  let timeout
  try {
    return await Promise.race([
      run.exited,
      new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Quit waited for readiness past the native fallback deadline')), 2_500) }),
    ])
  } finally { clearTimeout(timeout) }
}

test('packaged launcher starts from a path with spaces and Quit closes its bridge', async t => {
  const root = await fixture(t)
  const run = start(root)
  t.after(() => run.child.kill())
  const ready = await run.event('ready')
  assert.equal(ready.owned, true)
  assert.equal((await (await fetch(`${ready.url}/health`)).json()).service, 'lumendesk-bridge')
  run.child.stdin.write('quit\n')
  assert.equal((await run.exited)[0], 0)
  await assert.rejects(fetch(ready.url))
  assert.throws(() => process.kill(run.childPID(), 0), { code: 'ESRCH' })
})

test('closing the native wrapper input shuts down the bridge', async t => {
  const root = await fixture(t)
  const run = start(root)
  t.after(() => run.child.kill())
  const ready = await run.event('ready')
  run.child.stdin.end()
  assert.equal((await run.exited)[0], 0)
  await assert.rejects(fetch(ready.url))
})

test('Quit during slow startup closes the bridge before the native fallback deadline', async t => {
  const root = await fixture(t)
  // Windows force-closes a stuck native wrapper after three seconds. The
  // bridge must be stopped sooner even when readiness has not arrived yet.
  const slow = stub.replace(
    "console.log('LumenDesk is running. Open http://127.0.0.1:' + server.address().port);",
    "setTimeout(() => console.log('LumenDesk is running. Open http://127.0.0.1:' + server.address().port), 5_000);",
  )
  await fs.writeFile(path.join(root, 'web', 'bridge', 'src', 'index.js'), slow)
  const run = start(root)
  const pid = await run.childStarted()
  t.after(() => {
    run.child.kill()
    try { process.kill(pid, 'SIGKILL') } catch { /* Cleanup after a failed assertion. */ }
  })
  run.child.stdin.write('qu')
  run.child.stdin.write('it\n')
  assert.equal((await exitBeforeFallback(run))[0], 0)
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' })
})

test('Quit during the owned bridge health request cancels network handles and drains child pipes', async t => {
  const root = await fixture(t)
  const slowHealth = stub.replace('const server = http.createServer((req, res) => {', `const server = http.createServer((req, res) => {
    if (req.url === '/health') {
      console.error('health-request');
      setTimeout(() => { res.end('{"ok":true,"service":"lumendesk-bridge"}'); }, 5_000);
      return;
    }`)
  await fs.writeFile(path.join(root, 'web', 'bridge', 'src', 'index.js'), slowHealth)
  const run = start(root)
  const pid = await run.childStarted()
  t.after(() => {
    run.child.kill()
    try { process.kill(pid, 'SIGKILL') } catch { /* Cleanup after a failed assertion. */ }
  })
  await run.stderrMatch(/health-request/)
  run.child.stdin.write('quit\n')
  assert.equal((await exitBeforeFallback(run))[0], 0)
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' })
  assert.doesNotMatch(run.output(), /"event":"error"/)
})

test('Quit during an existing-service probe does not spawn a later bridge', async t => {
  const root = await fixture(t)
  let received
  const requested = new Promise(resolve => { received = resolve })
  const server = http.createServer(() => received())
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve) }))
  const run = start(root, server.address().port)
  t.after(() => run.child.kill())
  await requested
  run.child.stdin.write('quit\n')
  assert.equal((await exitBeforeFallback(run))[0], 0)
  assert.ok(Number.isNaN(run.childPID()))
  assert.doesNotMatch(run.output(), /"event":"error"/)
})

test('an incomplete existing-service response fails promptly without leaving a request deadline', async t => {
  const root = await fixture(t)
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': '100' })
    res.write('{')
    setImmediate(() => res.destroy())
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise(resolve => server.close(resolve)))
  const run = start(root, server.address().port)
  t.after(() => run.child.kill())
  assert.match((await run.event('error')).message, /did not answer as LumenDesk/)
  assert.equal((await exitBeforeFallback(run))[0], 1)
  assert.ok(Number.isNaN(run.childPID()))
})

test('an existing bridge is reused without taking ownership or stopping it', async t => {
  const root = await fixture(t)
  const first = start(root)
  t.after(() => first.child.kill())
  const ready = await first.event('ready')
  const second = start(root, Number(new URL(ready.url).port))
  t.after(() => second.child.kill())
  assert.deepEqual(await second.event('ready'), { event: 'ready', url: ready.url, owned: false })
  assert.equal((await second.exited)[0], 0)
  assert.equal((await fetch(ready.url)).status, 200)
  first.child.stdin.write('quit\n')
  assert.equal((await first.exited)[0], 0)
})

test('another application on the port produces a useful error and stays running', async t => {
  const root = await fixture(t)
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json')
    res.end('{"service":"other-app"}')
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise(resolve => server.close(resolve)))
  const run = start(root, server.address().port)
  assert.match((await run.event('error')).message, /already in use by another application/)
  assert.equal((await run.exited)[0], 1)
  assert.equal((await fetch(`http://127.0.0.1:${server.address().port}/health`)).status, 200)
  assert.ok(Number.isNaN(run.childPID()))
})

test('an unexpected bridge exit becomes a launcher error', async t => {
  const root = await fixture(t)
  const run = start(root)
  t.after(() => run.child.kill())
  await run.event('ready')
  process.kill(run.childPID(), 'SIGKILL')
  assert.match((await run.event('error')).message, /stopped unexpectedly/)
  assert.equal((await run.exited)[0], 1)
})

test('Linux desktop Open and Stop use a private control socket and close the bridge', { skip: process.platform !== 'linux' }, async t => {
  const root = await fixture(t)
  const bin = path.join(root, 'bin')
  await fs.mkdir(bin)
  await fs.writeFile(path.join(bin, 'xdg-open'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
  const env = { ...process.env, HOME: root, USERPROFILE: root, PATH: `${bin}:${process.env.PATH}` }
  const first = start(root, 0, ['--desktop'], { env })
  t.after(() => first.child.kill())
  const ready = await first.event('ready')
  const socket = path.join(root, '.lumendesk', 'launcher.sock')
  let stat
  for (let retry = 0; retry < 30; retry++) {
    try { stat = await fs.stat(socket); break } catch { await new Promise(resolve => setTimeout(resolve, 10)) }
  }
  assert.ok(stat?.isSocket())
  assert.equal(stat.mode & 0o777, 0o600)
  const second = start(root, 0, ['--desktop'], { env })
  assert.equal((await second.exited)[0], 0)
  assert.equal((await fetch(ready.url)).status, 200)
  const stop = start(root, 0, ['--stop'], { env })
  assert.equal((await stop.exited)[0], 0)
  assert.equal((await first.exited)[0], 0)
  await assert.rejects(fetch(ready.url))
  await assert.rejects(fs.stat(socket), { code: 'ENOENT' })
})
