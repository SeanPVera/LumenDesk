import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MetreTracker } from '../.test-build/metre.js'

test('half-time follows alternating beat weight with either beat offset', () => {
  for (const strongParity of [0, 1]) {
    const tracker = new MetreTracker()
    for (let beat = 0; beat < 64; beat += 1) {
      tracker.observe(beat, beat % 2 === strongParity ? 1 : .1, 150, true)
      if (beat >= 24) {
        assert.equal(tracker.current().feel, 'half', `strong parity ${strongParity}, beat ${beat}`)
      }
    }
  }
})

test('slow alternating beat weight stays straight with either beat offset', () => {
  for (const strongParity of [0, 1]) {
    const tracker = new MetreTracker()
    for (let beat = 0; beat < 64; beat += 1) {
      tracker.observe(beat, beat % 2 === strongParity ? 1 : .1, 78, true)
      if (beat >= 24) {
        assert.equal(tracker.current().feel, 'straight', `strong parity ${strongParity}, beat ${beat}`)
      }
    }
  }
})

test('balanced slow pulses use double-time with either beat offset', () => {
  for (const offset of [0, 1]) {
    const tracker = new MetreTracker()
    for (let index = 0; index < 64; index += 1) {
      tracker.observe(index + offset, .8, 78, true)
      if (index >= 24) {
        assert.equal(tracker.current().feel, 'double', `offset ${offset}, beat ${index}`)
      }
    }
  }
})
