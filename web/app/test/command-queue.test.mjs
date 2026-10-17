import assert from 'node:assert/strict'
import { test } from 'node:test'
import { DeviceCommandQueue } from '../.test-build/setup/commandQueue.js'

test('continuous commands retain only the latest queued value for one light', async () => {
  const queue = new DeviceCommandQueue()
  const sent = []
  let release
  const hold = new Promise(resolve => { release = resolve })
  const first = queue.enqueue('lamp', 'brightness', async () => {
    sent.push(10)
    await hold
    return 10
  }, true)
  const second = queue.enqueue('lamp', 'brightness', async () => { sent.push(25); return 25 }, true)
  const third = queue.enqueue('lamp', 'brightness', async () => { sent.push(80); return 80 }, true)

  assert.equal(queue.has('lamp'), true)
  release()
  assert.deepEqual(await Promise.all([first, second, third]), [
    { ok: true, value: 10 }, { ok: true, value: 80 }, { ok: true, value: 80 },
  ])
  assert.deepEqual(sent, [10, 80])
  assert.equal(queue.has('lamp'), false)
})

test('different controls stay ordered, and another light can proceed independently', async () => {
  const queue = new DeviceCommandQueue()
  const sent = []
  let release
  const hold = new Promise(resolve => { release = resolve })
  const power = queue.enqueue('lamp', 'power', async () => {
    sent.push('power started')
    await hold
    sent.push('power finished')
    return 'power'
  })
  const brightness = queue.enqueue('lamp', 'brightness', async () => { sent.push('brightness'); return 'brightness' }, true)
  const color = queue.enqueue('lamp', 'color', async () => { sent.push('color'); return 'color' }, true)
  const other = queue.enqueue('other', 'power', async () => { sent.push('other'); return 'other' })
  assert.deepEqual(await other, { ok: true, value: 'other' })
  assert.deepEqual(sent, ['power started', 'other'])
  release()
  await Promise.all([power, brightness, color])
  assert.deepEqual(sent, ['power started', 'other', 'power finished', 'brightness', 'color'])
})

test('a failed command does not block the next command', async () => {
  const queue = new DeviceCommandQueue()
  const error = new Error('light did not answer')
  const first = queue.enqueue('lamp', 'power', async () => { throw error })
  const second = queue.enqueue('lamp', 'brightness', async () => 42, true)
  assert.deepEqual(await first, { ok: false, error })
  assert.deepEqual(await second, { ok: true, value: 42 })
})

test('connection change cancels unsent work and lets a new queue use the same light', async () => {
  const queue = new DeviceCommandQueue()
  const sent = []
  let releaseOld
  const oldHold = new Promise(resolve => { releaseOld = resolve })
  const oldActive = queue.enqueue('lamp', 'brightness', async () => {
    sent.push('old active')
    await oldHold
    return 10
  }, true)
  const oldQueued = queue.enqueue('lamp', 'brightness', async () => { sent.push('old queued'); return 20 }, true)
  queue.cancelAll()
  assert.equal((await oldActive).cancelled, true)
  assert.equal((await oldQueued).cancelled, true)

  let releaseNew
  const newHold = new Promise(resolve => { releaseNew = resolve })
  const replacement = queue.enqueue('lamp', 'brightness', async () => {
    sent.push('new active')
    await newHold
    return 80
  }, true)
  releaseOld()
  await oldHold
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(queue.has('lamp'), true, 'old drain must not remove the replacement queue')
  releaseNew()
  assert.deepEqual(await replacement, { ok: true, value: 80 })
  assert.deepEqual(sent, ['old active', 'new active'])
})
