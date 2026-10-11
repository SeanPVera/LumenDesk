import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MusicFeatureAnalyzer } from '../.test-build/analyzer.js'
import { hannWindow } from '../.test-build/fft.js'
import { emptySnapshot } from '../.test-build/types.js'

const WINDOW = 2048
const HOP = 512

function chronologicalWindow(stream, end) {
  return Array.from({ length: WINDOW }, (_, i) => stream[end - WINDOW + i] ?? 0)
}

function meanSquare(samples) {
  return samples.reduce((sum, value) => sum + value * value, 0) / samples.length
}

test('channel windows preserve chronological order and Hann alignment across wrap points', () => {
  const analyzer = new MusicFeatureAnalyzer()
  const hann = hannWindow(WINDOW)
  const windowed = new Float64Array(WINDOW)
  const chronological = Array.from({ length: WINDOW }, (_, i) => (i - 997) / WINDOW)
  for (const write of [0, 1, 511, 512, 1024, 1536, WINDOW - 1]) {
    const ring = Float64Array.from(chronological.slice(WINDOW - write).concat(chronological.slice(0, WINDOW - write)))
    analyzer.ringWrite = write
    assert.equal(analyzer.windowChannel(ring, windowed), meanSquare(chronological), `mean square at ${write}`)
    assert.deepEqual(Array.from(windowed), chronological.map((sample, i) => sample * hann[i]), `window at ${write}`)
  }
})

test('irregular mono and stereo buffers retain every sample and publish only complete hops', () => {
  const hann = hannWindow(WINDOW)
  const counts = [1, 127, 383, 1, 2047, 3, 4097, 17, 509, 2048]
  const total = counts.reduce((sum, count) => sum + count, 0)
  const left = Float64Array.from({ length: total }, (_, i) => .35 * Math.sin(i * .071) + .12 * Math.cos(i * .013))
  const right = Float64Array.from({ length: total }, (_, i) => -.2 * Math.sin(i * .041) + .05 * Math.cos(i * .17))
  for (const stereo of [false, true]) {
    const analyzer = new MusicFeatureAnalyzer('Irregular buffers')
    const streams = stereo ? [left, right] : [left]
    const originalMagnitudes = analyzer.fft.magnitudes.bind(analyzer.fft)
    const originalStereoMagnitudes = analyzer.fft.stereoMagnitudes.bind(analyzer.fft)
    let transforms = 0, checkedWindows = 0
    const checkWindow = (input, stream) => {
      const expected = chronologicalWindow(stream, analyzer.processedSamples).map((sample, i) => sample * hann[i])
      assert.deepEqual(Array.from(input), expected, `FFT window ${transforms}, stereo=${stereo}`)
      checkedWindows++
    }
    analyzer.fft.magnitudes = (input, output) => {
      assert.equal(stereo, false, 'stereo capture uses one packed transform')
      checkWindow(input, left)
      transforms++
      originalMagnitudes(input, output)
    }
    analyzer.fft.stereoMagnitudes = (leftInput, rightInput, output) => {
      assert.equal(stereo, true)
      checkWindow(leftInput, left)
      checkWindow(rightInput, right)
      transforms++
      originalStereoMagnitudes(leftInput, rightInput, output)
    }
    let offset = 0
    let previousHop = 0
    for (const count of counts) {
      const samples = left.subarray(offset, offset + count)
      const channels = stereo ? { left: samples, right: right.subarray(offset, offset + count) } : undefined
      offset += count
      const snapshot = analyzer.analyze(samples, 100 + offset / 48000, channels)
      const completed = Math.floor(offset / HOP) * HOP
      if (completed === previousHop) {
        assert.equal(snapshot, null)
      } else {
        assert.equal(snapshot.analyzedSamples, completed)
        const expectedSquare = streams.reduce((sum, stream) => sum + meanSquare(chronologicalWindow(stream, completed)), 0) / streams.length
        assert.equal(snapshot.rawRMS, Math.sqrt(expectedSquare))
        assert.ok(Math.abs(snapshot.analysisTimestamp - (100 + completed / 48000)) < 1e-12)
        assert.equal(analyzer.latest(), snapshot)
      }
      previousHop = completed
    }
    assert.equal(transforms, Math.floor(total / HOP))
    assert.equal(checkedWindows, Math.floor(total / HOP) * streams.length)
    assert.equal(analyzer.processedSamples, total)
  }
})

test('missing stereo values retain image fallbacks while analysis treats missing channels as silence', () => {
  const samples = new Float64Array(WINDOW).fill(.25)
  const right = new Float64Array(WINDOW).fill(.75)
  const analyzer = new MusicFeatureAnalyzer('Sparse stereo')
  const snapshot = analyzer.analyze(samples, 100, { left: [], right })
  assert.equal(snapshot.stereo, .75)
  assert.equal(snapshot.rawRMS, Math.sqrt(.75 * .75 / 2))

  const left = new Float64Array(WINDOW).fill(.5)
  const missingRight = new MusicFeatureAnalyzer().analyze(samples, 100, { left, right: [] })
  assert.equal(missingRight.stereo, .5)
  assert.equal(missingRight.rawRMS, Math.sqrt(.5 * .5 / 2))
})

test('a multi-hop buffer retains aged transient peaks and final analysis state', () => {
  const analyzer = new MusicFeatureAnalyzer('Multi-hop')
  const byHop = new MusicFeatureAnalyzer('Multi-hop')
  const silent = new Float64Array(WINDOW)
  analyzer.analyze(silent, 100)
  byHop.analyze(silent, 100)
  const hit = new Float64Array(WINDOW * 3)
  for (let i = 0; i < 12; i++) hit[i] = i % 2 ? -1 : 1
  const hops = []
  for (let offset = 0; offset < hit.length; offset += HOP) {
    hops.push(byHop.analyze(hit.subarray(offset, offset + HOP), 100 + (offset + HOP) / 48000))
  }
  const snapshot = analyzer.analyze(hit, 100 + hit.length / 48000)
  assert.ok(hops.some(hop => hop.beat > 0), 'the initial transient produces a beat')
  assert.equal(hops.at(-1).beat, 0, 'the last silent hop has no new beat')
  const transients = ['beat', 'kick', 'snare', 'percussion', 'onset']
  for (const field of transients) {
    const expected = Math.max(...hops.map(hop => hop[field] * Math.exp(-(snapshot.analyzedSamples - hop.analyzedSamples) / 48000 / .08)))
    assert.ok(Math.abs(snapshot[field] - expected) < 1e-12, `${field} retains the hit's original age`)
  }
  assert.ok(snapshot.beat < Math.max(...hops.map(hop => hop.beat)), 'an early beat is not retimed at full strength')
  for (const [field, value] of Object.entries(hops.at(-1))) {
    if (transients.includes(field)) continue
    if (typeof value === 'number') assert.ok(Math.abs(snapshot[field] - value) < 1e-12, `final ${field}`)
    else assert.deepEqual(snapshot[field], value, `final ${field}`)
  }
})

test('published snapshots include all fields and own their spectral arrays', () => {
  const analyzer = new MusicFeatureAnalyzer('Owned arrays')
  const samples = Float64Array.from({ length: WINDOW }, (_, i) => .4 * Math.sin(i * .03))
  const first = analyzer.analyze(samples, 100)
  for (const field of Object.keys(emptySnapshot())) assert.ok(field in first, `missing ${field}`)
  const saved = structuredClone(first)
  const second = analyzer.analyze(new Float64Array(WINDOW), 100 + WINDOW / 48000)
  assert.notEqual(first.chroma, second.chroma)
  assert.notEqual(first.spectrum, second.spectrum)
  assert.deepEqual(first, saved)
  assert.notDeepEqual(second.spectrum, first.spectrum)
})
