import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MusicFeatureAnalyzer } from '../.test-build/analyzer.js'
import { MusicChoreographyEngine } from '../.test-build/choreography.js'
import { configurationFor } from '../.test-build/config.js'
import { emptySnapshot, freshSnapshot, retainUnrenderedTransients } from '../.test-build/types.js'

const fixtures = [{ id: 'a', label: 'A', transport: 'lifxLAN', segmentCount: 0, role: 'hit' }]
const topology = { layout: 'leftToRight', fixtureOrder: ['a'], excludedFixtureIDs: [] }
const configuration = {
  ...configurationFor('soundcheck'), movementAmount: 0, phraseAware: false,
  allowsFlashes: true, photosensitivitySafeMode: false, flashIntensity: 1,
  maximumFlashFrequency: 3, percussionSensitivity: 1,
}
const quiet = () => ({ ...emptySnapshot(), level: .4, energy: .4, confidence: 1 })

test('expired mapped input no longer claims a map or keeps a loud energy gear', () => {
  const mapped = { ...quiet(), analysisTimestamp: 100, beatMapActive: true, barEnergy: 1,
    isTempoLocked: true, tempo: 120, beatConfidence: 1 }
  const expired = freshSnapshot(mapped, 102)
  assert.equal(expired.beatMapActive, false)
  assert.equal(expired.barEnergy, undefined)
  assert.equal(expired.isTempoLocked, false)
})

function warmedEngine() {
  const engine = new MusicChoreographyEngine()
  for (let i = 0; i < 200; i++) {
    const timestamp = 90 + i * .05
    engine.makeFrame({ ...quiet(), analysisTimestamp: timestamp }, configuration, topology, fixtures, timestamp, i)
  }
  return engine
}

test('a repeated captured hit peaks immediately and cannot flash a second time', () => {
  const engine = warmedEngine()
  const hit = { ...quiet(), beat: 1, pulse: 1, snare: 1, analysisTimestamp: 100 }
  const frames = Array.from({ length: 21 }, (_, i) =>
    engine.makeFrame(hit, configuration, topology, fixtures, 100 + i * .05, 200 + i))
  const brightness = frames.map(frame => frame.states[0].brightness)
  assert.equal(frames.filter(frame => frame.flashApplied).length, 1, 'one captured snare is one flash request')
  assert.equal(brightness.indexOf(Math.max(...brightness)), 0, 'a frozen hit cannot swell for 250 ms')
  assert.ok(brightness[14] < brightness[0] * .5, 'the accent releases while the loudness bed remains')
})

test('a frozen pulse releases from the initial render instead of holding its attack', () => {
  const engine = warmedEngine()
  const hit = { ...quiet(), beat: 1, pulse: 1, analysisTimestamp: 100 }
  const brightness = Array.from({ length: 16 }, (_, i) =>
    engine.makeFrame(hit, configuration, topology, fixtures, 100 + i * .05, 200 + i).states[0].brightness)
  assert.ok(brightness.indexOf(Math.max(...brightness)) <= 1)
  assert.ok(brightness[5] < brightness[1], 'no flat full-strength transient through the freshness grace period')
})

test('a captured PCM kick releases when capture stops during its attack', () => {
  const analyzer = new MusicFeatureAnalyzer('PCM kick timing')
  const rate = 48000, chunk = 512
  let hit
  for (let offset = 0; offset < rate * .125; offset += chunk) {
    const pcm = Float32Array.from({ length: chunk }, (_, i) => {
      const t = (offset + i) / rate, phase = t - .1
      return phase < 0 ? 0 : .7 * Math.sin(2 * Math.PI * 65 * t) *
        Math.exp(-phase / .045) * (1 - Math.exp(-phase / .002))
    })
    hit = analyzer.analyze(pcm, 100 + (offset + chunk) / rate, undefined, rate)
  }
  assert.ok(hit.pulse > .5, 'the real Hann/FFT analyzer captured the kick')
  assert.equal(hit.isTempoLocked, false, 'one kick cannot establish a grid')
  const engine = warmedEngine(), config = { ...configuration, allowsFlashes: false }
  const brightness = Array.from({ length: 12 }, (_, i) =>
    engine.makeFrame(hit, config, topology, fixtures, hit.analysisTimestamp + i * .05, 200 + i).states[0].brightness)
  assert.ok(brightness.indexOf(Math.max(...brightness)) <= 1, 'the stopped PCM buffer cannot postpone its accent')
  assert.ok(brightness[5] < brightness[0], 'the pulse releases over 250 ms while the captured loudness bed holds')
})

test('fresh captured features preserve their values and synthetic snapshots stay unchanged', () => {
  const captured = {
    ...quiet(), beat: 1, kick: .8, snare: .7, percussion: .6, onset: .5, pulse: .9,
    drop: .8, isTempoLocked: true, tempo: 120, beatInterval: .5,
    beatConfidence: .9, beatReferenceTime: 99.5, analysisTimestamp: 100,
  }
  assert.deepEqual(freshSnapshot(captured, 100), captured)
  assert.deepEqual(freshSnapshot(captured, 99.9), captured)
  const { analysisTimestamp, ...synthetic } = captured
  assert.equal(freshSnapshot(synthetic, 110), synthetic)
  const delayed = freshSnapshot(captured, 100.1)
  assert.equal(delayed.level, captured.level, 'loudness retains its capture freshness grace')
  assert.ok(Math.abs(delayed.snare - captured.snare * Math.exp(-.1 / .08)) < 1e-12)
  assert.ok(Math.abs(delayed.pulse - captured.pulse * Math.exp(-.1 / (.5 * .42))) < 1e-12)
  assert.equal(delayed.beatReferenceTime, captured.beatReferenceTime)
  assert.equal(delayed.beatInterval, captured.beatInterval)
  assert.equal(delayed.isTempoLocked, true)
})

test('continuous captured pulses keep the output of the same live musical grid', () => {
  const capturedEngine = new MusicChoreographyEngine()
  const syntheticEngine = new MusicChoreographyEngine()
  for (let i = 0; i < 100; i++) {
    const timestamp = 100 + i * .05
    const beatCount = Math.floor((timestamp - 100) / .5)
    const phase = (timestamp - 100) % .5
    const live = {
      ...quiet(), beat: phase < .025 ? 1 : 0, pulse: Math.exp(-phase / .21),
      snare: phase < .025 ? .7 : 0, isTempoLocked: true, tempo: 120,
      beatInterval: .5, feltInterval: .5, beatConfidence: 1, beatCount,
      gridBeatPosition: beatCount, beatInBar: beatCount % 4,
      beatReferenceTime: 100 + beatCount * .5,
    }
    const expected = syntheticEngine.makeFrame(live, configuration, topology, fixtures, timestamp, i)
    const actual = capturedEngine.makeFrame({ ...live, analysisTimestamp: timestamp }, configuration, topology, fixtures, timestamp, i)
    assert.deepEqual(actual, expected)
  }
})

test('unrendered transient aggregation preserves capture time across multiple handoffs', () => {
  const hit = { ...quiet(), snare: .95, percussion: .8, beat: 1, analysisTimestamp: 100.01 }
  const intermediate = retainUnrenderedTransients({ ...quiet(), analysisTimestamp: 100.025 }, hit)
  const latest = { ...quiet(), level: .2, beatCount: 7, analysisTimestamp: 100.032 }
  const twice = retainUnrenderedTransients(latest, intermediate)
  const once = retainUnrenderedTransients(latest, hit)
  for (const key of ['beat', 'snare', 'percussion']) {
    assert.ok(Math.abs(twice[key] - once[key]) < 1e-12, 'publication batching does not stretch the envelope')
  }
  assert.equal(twice.level, .2)
  assert.equal(twice.beatCount, 7)
  assert.equal(twice.analysisTimestamp, latest.analysisTimestamp)
  assert.equal(latest.snare, 0, 'aggregation never mutates an analyzer-owned snapshot')
  assert.equal(retainUnrenderedTransients(hit, latest), hit, 'future captures cannot be folded into earlier music')
  const frame = warmedEngine().makeFrame(twice, configuration, topology, fixtures, 100.04, 200)
  assert.equal(frame.flashApplied, true, 'the first hit survives a later quiet capture before the render tick')
  const delayed = freshSnapshot(twice, 100.21)
  assert.ok(Math.abs(delayed.snare - .95 * Math.exp(-.2 / .08)) < 1e-12,
    'slow rendering decays from the original hit time')
})

test('unrendered hits cannot cross a restarted sample clock or newly dropped capture', () => {
  const hit = { ...quiet(), snare: 1, analysisTimestamp: 100, analyzedSamples: 2048, droppedBuffers: 0 }
  for (const metadata of [
    { analyzedSamples: 1024, droppedBuffers: 0 },
    { analyzedSamples: 2048, droppedBuffers: 0 },
    { analyzedSamples: 3072, droppedBuffers: 1 },
  ]) {
    const restarted = { ...quiet(), analysisTimestamp: 100.02, ...metadata }
    assert.equal(retainUnrenderedTransients(restarted, hit), restarted)
    assert.equal(restarted.snare, 0)
  }
  const continuing = { ...quiet(), analysisTimestamp: 100.02, analyzedSamples: 3072, droppedBuffers: 0 }
  assert.ok(retainUnrenderedTransients(continuing, hit).snare > .7)
  const unknownClockHit = { ...hit, analyzedSamples: 0 }
  const unknownClockNext = { ...continuing, analyzedSamples: 0 }
  assert.ok(retainUnrenderedTransients(unknownClockNext, unknownClockHit).snare > .7,
    'default zero metadata does not mark MIDI or explicit snapshots as a stream reset')
})
