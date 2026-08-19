// The bridge can serve the built web client from its own origin, which is the
// route that avoids CORS and the browser's local-network permission entirely.
import { test, before, after } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Registry } from '../src/registry.js'
import { LifxClient } from '../src/lifx-client.js'
import { GoveeClient } from '../src/govee-client.js'
import { createServer } from '../src/server.js'
import { isBuiltApp } from '../src/static.js'

let dir, server, base, secret, clients

before(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-app-'))
  await fs.mkdir(path.join(dir, 'assets'))
  await fs.writeFile(path.join(dir, 'index.html'), '<!doctype html><title>LumenDesk</title>')
  await fs.writeFile(path.join(dir, 'assets', 'app.js'), 'console.log(1)')
  await fs.writeFile(path.join(dir, 'favicon.svg'), '<svg/>')

  // A file outside the served root that traversal must never reach.
  secret = path.join(path.dirname(dir), `secret-${path.basename(dir)}.txt`)
  await fs.writeFile(secret, 'TOP SECRET')

  const registry = new Registry()
  const lifx = new LifxClient({ registry, discoveryAddress: '127.0.0.1' })
  const govee = new GoveeClient({ registry, responsePort: 0, joinMulticast: false })
  await lifx.start()
  await govee.start()

  server = createServer({
    registry,
    lifx,
    govee,
    allowedOrigins: ['*'],
    version: 'test',
    staticDir: dir,
  })
  await new Promise(r => server.listen(0, '127.0.0.1', r))
  base = `http://127.0.0.1:${server.address().port}`
  clients = { lifx, govee }
})

after(async () => {
  clients?.lifx.stop()
  clients?.govee.stop()
  server?.close()
  await fs.rm(dir, { recursive: true, force: true })
  await fs.rm(secret, { force: true })
})

test('isBuiltApp recognises a built client', async () => {
  assert.equal(isBuiltApp(dir), true)
  assert.equal(isBuiltApp(path.join(dir, 'assets')), false)
  assert.equal(isBuiltApp('/definitely/not/here'), false)
})

test('serves the client at the root with the right content type', async () => {
  const res = await fetch(`${base}/`)
  assert.equal(res.status, 200)
  assert.match(res.headers.get('content-type'), /text\/html/)
  assert.match(await res.text(), /LumenDesk/)
})

test('serves hashed assets and other static files', async () => {
  const js = await fetch(`${base}/assets/app.js`)
  assert.equal(js.status, 200)
  assert.match(js.headers.get('content-type'), /javascript/)
  assert.equal(await js.text(), 'console.log(1)')

  const svg = await fetch(`${base}/favicon.svg`)
  assert.equal(svg.status, 200)
  assert.equal(svg.headers.get('content-type'), 'image/svg+xml')
})

test('API routes are not shadowed by static files', async () => {
  const health = await fetch(`${base}/health`)
  assert.equal(health.status, 200)
  assert.equal((await health.json()).service, 'lumendesk-bridge')

  const devices = await fetch(`${base}/devices`)
  assert.equal(devices.status, 200)
  assert.ok(Array.isArray((await devices.json()).devices))
})

test('unknown paths fall back to the client, not a 404', async () => {
  const res = await fetch(`${base}/some/deep/route`)
  assert.equal(res.status, 200)
  assert.match(await res.text(), /LumenDesk/)
})

test('path traversal cannot escape the served directory', async () => {
  const attempts = [
    '/../' + path.basename(secret),
    '/../../etc/passwd',
    '/assets/../../' + path.basename(secret),
    '/%2e%2e/%2e%2e/etc/passwd',
    '/..%2f..%2fetc%2fpasswd',
  ]
  for (const attempt of attempts) {
    const res = await fetch(`${base}${attempt}`, { redirect: 'manual' })
    const body = await res.text()
    assert.ok(!body.includes('TOP SECRET'), `leaked a file outside the root via ${attempt}`)
    assert.ok(!body.includes('root:'), `leaked /etc/passwd via ${attempt}`)
  }
})

test('a POST to an unknown path is still a JSON 404, not the client', async () => {
  const res = await fetch(`${base}/not/a/route`, { method: 'POST' })
  assert.equal(res.status, 404)
  assert.equal((await res.json()).error, 'not found')
})
