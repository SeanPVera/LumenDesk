import { test } from 'node:test'
import assert from 'node:assert/strict'
import { RealFFT, hannWindow } from '../.test-build/fft.js'
import { MusicFeatureAnalyzer } from '../.test-build/analyzer.js'

test('production-size FFT agrees with a direct DFT after mixed mono and stereo reuse', () => {
  for (const size of [512, 1024, 2048]) {
    const window = hannWindow(size)
    const left = Float64Array.from({ length: size }, (_, i) => window[i] * (.13 + .6 * Math.sin(i * .971) + .21 * Math.cos(i * .223)))
    const right = Float64Array.from({ length: size }, (_, i) => window[i] * (-.17 + .3 * Math.sin(i * .714 + .3)))
    const fft = new RealFFT(size), output = new Float64Array(size / 2)
    for (const stereo of [true, false, true]) {
      if (stereo) fft.stereoMagnitudes(left, right, output)
      else fft.magnitudes(left, output)
      for (const bin of [0, 1, 3, 18, 39, Math.floor(size * .14), size / 2 - 1]) {
        const power = signal => {
          let re = 0, im = 0
          for (let i = 0; i < size; i++) {
            const angle = -2 * Math.PI * bin * i / size
            re += signal[i] * Math.cos(angle)
            im += signal[i] * Math.sin(angle)
          }
          return (re * re + im * im) * ((bin === 0 ? 1 : 2) / size) ** 2
        }
        const expected = Math.sqrt(stereo ? (power(left) + power(right)) / 2 : power(left))
        assert.ok(Math.abs(output[bin] - expected) < 2e-12, `size ${size}, stereo ${stereo}, bin ${bin}`)
      }
    }
  }
})

test('capture buffers retain aged transient peaks while preserving spectral and beat state', () => {
  const rate = 44100, length = rate * 6
  const left = Float32Array.from({ length }, (_, i) => {
    const t = i / rate, phase = t % .5
    return .7 * Math.sin(2 * Math.PI * 65 * t) * Math.exp(-phase / .045)
      + .16 * Math.sin(2 * Math.PI * 7900 * t) * Math.exp(-(t % .125) / .012)
  })
  const right = left.map((value, i) => -.8 * value + .07 * Math.sin(i * .34))
  const transientFields = ['beat', 'kick', 'snare', 'percussion', 'onset']
  // A single-hop capture is an independent reference for the feature history.
  // Each published buffer must retain every hit in that buffer, aged to the
  // timestamp of its final analyzed hop, including uneven capture partitions.
  const reference = new MusicFeatureAnalyzer('Partition test'), hops = new Map()
  for (let offset = 0; offset < length; offset += 512) {
    const end = Math.min(length, offset + 512)
    const stereo = { left: left.subarray(offset, end), right: right.subarray(offset, end) }
    const snapshot = reference.analyze(stereo.left, 100 + end / rate, stereo, rate)
    if (snapshot) hops.set(snapshot.analyzedSamples, snapshot)
  }
  const analyze = chunkSizes => {
    const analyzer = new MusicFeatureAnalyzer('Partition test')
    let offset = 0, chunkIndex = 0, lastAnalyzedSample = 0
    while (offset < length) {
      const end = Math.min(length, offset + chunkSizes[chunkIndex++ % chunkSizes.length])
      const stereo = { left: left.subarray(offset, end), right: right.subarray(offset, end) }
      const snapshot = analyzer.analyze(stereo.left, 100 + end / rate, stereo, rate)
      if (snapshot) {
        for (const field of transientFields) {
          let peak = 0
          for (let sample = lastAnalyzedSample + 512; sample <= snapshot.analyzedSamples; sample += 512) {
            const age = (snapshot.analyzedSamples - sample) / rate
            peak = Math.max(peak, hops.get(sample)[field] * Math.exp(-age / .08))
          }
          assert.ok(Math.abs(snapshot[field] - peak) < 1e-11,
            `${field} at sample ${snapshot.analyzedSamples}: ${snapshot[field]} vs aged peak ${peak}`)
        }
        lastAnalyzedSample = snapshot.analyzedSamples
      }
      offset = end
    }
    return analyzer.latest()
  }
  const regular = analyze([1024]), uneven = analyze([163, 691, 512, 1536, 409, 2677])
  for (const field of ['level', 'bass', 'mids', 'highs', 'pulse', 'energy', 'rawRMS', 'tempo', 'beatInterval', 'beatConfidence', 'beatReferenceTime', 'analyzedSamples', 'beatCount', 'gridBeatPosition']) {
    assert.ok(Math.abs(regular[field] - uneven[field]) < 1e-11, `${field}: ${regular[field]} vs ${uneven[field]}`)
  }
  assert.deepEqual(regular.chroma, uneven.chroma)
  assert.deepEqual(regular.spectrum, uneven.spectrum)
})

test('silence clears stale spectra while extremely quiet input retains its pitch energy', () => {
  const rate = 48000, chunk = 1024, analyzer = new MusicFeatureAnalyzer()
  let end = 100
  const feed = (amplitude, count) => {
    for (let buffer = 0; buffer < count; buffer++) {
      const samples = Float32Array.from({ length: chunk }, (_, i) => amplitude * Math.sin(2 * Math.PI * 440 * (buffer * chunk + i) / rate))
      end += chunk / rate
      analyzer.analyze(samples, end, { left: samples, right: samples.map(v => -v) }, rate)
    }
    return analyzer.latest()
  }
  feed(.5, 10)
  const silent = feed(0, 100)
  assert.equal(silent.rawRMS, 0)
  assert.equal(silent.onset, 0)
  assert.ok(silent.chroma.every(value => value === 0))
  assert.ok(silent.spectrum.every(value => value < 1e-12))
  const quiet = feed(1e-14, 10)
  assert.ok(quiet.rawRMS > 0)
  assert.equal(Math.max(...quiet.chroma), 1)
  assert.ok(quiet.spectrum.some(value => value > 0))
})
