import { test } from 'node:test'
import assert from 'node:assert/strict'
import { countDiscoveryReplies, summarizeDiscovery } from '../.test-build/setup/discovery.js'
import { checkHealth, startDiscovery } from '../.test-build/setup/bridge.js'

const probe = patch => ({ interfaces: ['Wi-Fi'], sent: 253, failed: 0, unoccupied: 250, lastError: null, ...patch })
const discovery = (lifx = probe(), govee = probe(), nanoleaf = null) => ({ ok: true, probes: { lifx, govee, nanoleaf } })

test('a stale reachable light cannot count as answering the current search', () => {
  assert.equal(countDiscoveryReplies([
    { id: 'lifx:old', reachable: true, lastSeen: 1000 },
    { id: 'govee:new', reachable: true, lastSeen: 5000 },
  ], 4000), 1)
  assert.equal(countDiscoveryReplies([{ id: 'lifx:old', reachable: true, lastSeen: 1000 }], 4000), 0)
})

test('an older bridge without freshness metadata does not invent a reply count', () => {
  assert.equal(countDiscoveryReplies([{ id: 'lifx:old', reachable: true }], 4000), null)
  assert.equal(countDiscoveryReplies([], 4000), 0)
})

test('a healthy sweep with empty addresses is silence, not a network failure', () => {
  const summary = summarizeDiscovery(discovery(), 0)
  assert.equal(summary.outcome, 'silent')
  assert.equal(summary.sent, 506)
  assert.equal(summary.unoccupied, 500)
  assert.equal(summary.failed, 0)
})

test('queued Nanoleaf refreshes cannot hide an inability to send network probes', () => {
  const summary = summarizeDiscovery(discovery(probe({ sent: 0, failed: 2 }), probe({ sent: 0 }), { sent: 2, paired: 2 }), 2)
  assert.equal(summary.outcome, 'blocked')
  assert.equal(summary.sent, 0)
  assert.match(summary.detail, /2 lights answered/)
})

test('a refused send remains actionable even when other lights answered', () => {
  const summary = summarizeDiscovery(discovery(probe({ failed: 1, lastError: 'ENETUNREACH' })), 1)
  assert.equal(summary.outcome, 'partial')
  assert.match(summary.errors[0], /LIFX.*ENETUNREACH/)
  assert.match(summary.detail, /1 light answered/)
})

test('rejected vendor passes are distinguished from no answering lights', () => {
  assert.equal(summarizeDiscovery(discovery({ error: 'socket closed' }, { error: 'socket closed' }), 0).outcome, 'blocked')
  assert.equal(summarizeDiscovery(discovery({ error: 'socket closed' }, probe()), 0).outcome, 'partial')
})

test('successful fresh replies show lights available without claiming physical output', () => {
  const summary = summarizeDiscovery(discovery(), 2)
  assert.equal(summary.outcome, 'ready')
  assert.equal(summary.detail, '2 lights answered during this search.')
})

test('an older bridge result stays usable without claiming probes succeeded', () => {
  const summary = summarizeDiscovery({ ok: true }, null)
  assert.equal(summary.outcome, 'unknown')
  assert.equal(summary.sent, null)
  assert.match(summary.detail, /does not report network probe diagnostics/)
})

test('Nanoleaf errors are actionable without being counted as UDP probe failures', () => {
  const summary = summarizeDiscovery(discovery(probe(), probe(), { error: 'controller unavailable' }), 1)
  assert.equal(summary.outcome, 'partial')
  assert.equal(summary.sent, 506)
  assert.equal(summary.failed, 0)
  assert.deepEqual(summary.errors, ['Nanoleaf: controller unavailable'])
})

test('discovery keeps a slow probe report while ordinary calls retain their short timeout', async t => {
  const timeouts = []
  const paths = []
  t.mock.method(AbortSignal, 'timeout', milliseconds => {
    timeouts.push(milliseconds)
    return new AbortController().signal
  })
  t.mock.method(globalThis, 'fetch', async url => {
    paths.push(url)
    return { ok: true, json: async () => url.endsWith('/discover') ? discovery() : { ok: true, service: 'lumendesk-bridge' } }
  })
  const result = await startDiscovery(8765)
  await checkHealth(8765)
  assert.deepEqual(timeouts, [60_000, 5000])
  assert.deepEqual(paths, ['http://127.0.0.1:8765/discover', 'http://127.0.0.1:8765/health'])
  assert.equal(result.probes.lifx.sent, 253)
})
