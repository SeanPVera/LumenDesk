import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  ENVELOPE_RATE, PlaybackClock, alignToBeatMap, analyzeAudioBuffer, applyBeatMap, beatMapGridAt,
  TapCalibrator, barEnergies, buildBeatMap, buildBeatMapAsync, isTrustworthyAlignment,
} from '../.test-build/beat-map.js'
import { EnergyTierTracker, MusicChoreographyEngine } from '../.test-build/choreography.js'
import { configurationFor } from '../.test-build/config.js'
import { emptySnapshot } from '../.test-build/types.js'

const HOP = 512 / 48000

test('equally loud bars get the same energy regardless of track order or bar count', () => {
  const beats = Array.from({ length: 16 }, (_, i) => i * 0.5)
  const energy = new Float64Array(800).fill(0.45)
  const bars = barEnergies(beats, 0, energy)
  assert.equal(bars.length, 4)
  for (const value of bars) assert.ok(Math.abs(value - 0.56) < 1e-9, `neutral rank: ${value}`)
  assert.ok(Math.abs(barEnergies(beats.slice(0, 4), 0, energy)[0] - bars[0]) < 1e-9)
  const mixed = Float64Array.from({ length: 800 }, (_, i) => i < 400 ? 0.2 : 0.8)
  const ranked = barEnergies(beats, 0, mixed)
  assert.ok(Math.abs(ranked[0] - ranked[1]) < 1e-9)
  assert.ok(Math.abs(ranked[2] - ranked[3]) < 1e-9)
  assert.ok(ranked[2] > ranked[0])
})

test('rapid or backwards calibration taps cannot count as separate beats', () => {
  const taps = new TapCalibrator()
  for (let i = 0; i < 8; i++) taps.tap(100.06 + i * 0.01, 100, 0.5)
  assert.equal(taps.count, 1)
  assert.equal(taps.suggestedOffset(0), null)
  taps.tap(100, 100, 0.5)
  taps.tap(100.56, 100.5, 0.5)
  assert.equal(taps.count, 2)
})

test('double-time colour steps remain at or below three per second', () => {
  const map = { ...quietMap(1), beats: Array.from({ length: 300 }, (_, i) => i * 0.3) }
  const engine = new MusicChoreographyEngine()
  const config = { ...configurationFor('balanced'), timeFeel: 'double', movementAmount: 0, stereoImage: 0 }
  const changes = []
  let previous = 0
  for (let step = 0; step < 1000; step++) {
    const position = 5 + step * 0.01, timestamp = 1000 + position
    const snapshot = engineSnapshot(map, position, timestamp)
    snapshot.timeFeel = 'double'
    snapshot.feltInterval = snapshot.beatInterval * 0.5
    engine.makeFrame(snapshot, config, { layout: 'leftToRight', fixtureOrder: [], excludedFixtureIDs: [] }, room(), timestamp, step)
    if (engine.paletteFadeTo > previous) changes.push(timestamp)
    previous = engine.paletteFadeTo
  }
  assert.ok(changes.length > 10)
  for (let i = 1; i < changes.length; i++) assert.ok(changes[i] - changes[i - 1] >= 1 / 3 - 0.011, 'colour changes exceed 3/s')
})

test('tempo jitter across the colour subdivision threshold cannot retrigger at render speed', () => {
  const engine = new MusicChoreographyEngine(), changes = []
  const config = { ...configurationFor('balanced'), movementAmount: 0, stereoImage: 0 }
  let previous = null
  for (let step = 0; step < 300; step++) {
    const elapsed = step * 0.01, timestamp = 100 + elapsed, beat = Math.floor(elapsed * 3)
    const interval = step % 2 === 0 ? 0.332 : 0.335
    const snapshot = { ...emptySnapshot(), analysisTimestamp: timestamp, level: 0.6, energy: 0.6, confidence: 1,
      beatConfidence: 1, isTempoLocked: true, tempo: 60 / interval, beatInterval: interval, feltInterval: interval,
      beatReferenceTime: 100 + beat / 3, gridBeatPosition: beat, beatCount: beat, beatInBar: beat % 4, barEnergy: 1 }
    engine.makeFrame(snapshot, config, { layout: 'leftToRight', fixtureOrder: [], excludedFixtureIDs: [] }, room(), timestamp, step)
    if (previous != null && engine.paletteFadeBar !== previous) changes.push(timestamp)
    previous = engine.paletteFadeBar
  }
  assert.ok(changes.length >= 3)
  for (let i = 1; i < changes.length; i++) assert.ok(changes[i] - changes[i - 1] >= 1 / 3 - 1e-6, 'jitter exceeded the colour-change limit')
})

/**
 * Synthetic hop features: a beat every `interval` seconds starting at
 * `firstBeat`, the downbeat on beat `downbeatBeat` of each four, louder kicks
 * on downbeats, and an energy step at `loudFrom`. The same vectors are used
 * by BeatMapTests.swift.
 */
function syntheticHops({ seconds = 60, interval = 0.5, firstBeat = 0.25, downbeatBeat = 0, loudFrom = 30 } = {}) {
  const hops = []
  for (let t = 0; t <= seconds; t += HOP) {
    const sinceFirst = t - firstBeat
    const index = Math.floor(sinceFirst / interval)
    const phase = sinceFirst - index * interval
    const onBeat = sinceFirst >= 0 ? Math.exp(-phase / 0.03) : 0
    const isDownbeat = ((index - downbeatBeat) % 4 + 4) % 4 === 0
    hops.push({
      time: t,
      onset: Math.min(1, onBeat * 0.9 + 0.02),
      kick: onBeat * (isDownbeat ? 1 : 0.35),
      energy: t >= loudFrom ? 0.8 : 0.35,
    })
  }
  return hops
}

test('a 120 BPM grid is recovered with its beats, downbeat and louder second half', () => {
  const map = buildBeatMap(syntheticHops())
  assert.ok(map, 'map')
  assert.ok(Math.abs(map.tempo - 120) < 1.5, `tempo ${map.tempo}`)
  for (let i = 1; i < map.beats.length; i += 1) {
    assert.ok(Math.abs(map.beats[i] - map.beats[i - 1] - 0.5) < 0.03, `interval at ${i}`)
  }
  for (const beat of map.beats) {
    const nearest = 0.25 + Math.round((beat - 0.25) / 0.5) * 0.5
    assert.ok(Math.abs(beat - nearest) < 0.03, `beat ${beat} near ${nearest}`)
  }
  const firstDownbeat = map.beats[map.downbeatOffset]
  assert.ok(Math.abs(((firstDownbeat - 0.25) / 0.5) % 4) < 0.1, `downbeat ${firstDownbeat}`)
  const early = map.barEnergy.slice(1, 10), late = map.barEnergy.slice(-10, -1)
  assert.ok(Math.min(...late) > Math.max(...early), 'loud bars rank above quiet ones')
  assert.ok(map.confidence > 0.2, `confidence ${map.confidence}`)
  assert.equal(map.envelope.length, Math.floor(map.duration * ENVELOPE_RATE) + 1)
})

test('a pickup puts the downbeat on the right beat and its grid positions on multiples of four', () => {
  const map = buildBeatMap(syntheticHops({ downbeatBeat: 2 }))
  assert.ok(map)
  const firstDownbeat = map.beats[map.downbeatOffset]
  const beatNumber = Math.round((firstDownbeat - 0.25) / 0.5)
  assert.equal(((beatNumber - 2) % 4 + 4) % 4, 0, `downbeat at beat ${beatNumber}`)
  const grid = beatMapGridAt(map, firstDownbeat + 0.01)
  assert.equal(grid.beatInBar, 0)
  assert.equal(grid.gridBeatPosition % 4, 0)
  const before = beatMapGridAt(map, map.beats[map.downbeatOffset + 3] + 0.01)
  assert.equal(before.beatInBar, 3)
})

test('too little audio or no pulse builds no map', () => {
  assert.equal(buildBeatMap(syntheticHops({ seconds: 5 })), null)
  const flat = syntheticHops({ seconds: 30 }).map(hop => ({ ...hop, onset: 0.3, kick: 0.1 }))
  assert.equal(buildBeatMap(flat), null)
})

test('the grid is absent before the first beat and after the last', () => {
  const map = buildBeatMap(syntheticHops())
  assert.equal(beatMapGridAt(map, map.beats[0] - 0.2), null)
  assert.equal(beatMapGridAt(map, map.beats.at(-1) + 2), null)
  const mid = beatMapGridAt(map, map.beats[20] + 0.1)
  assert.equal(mid.beatIndex, 20)
  assert.ok(Math.abs(mid.interval - 0.5) < 0.03)
})

test('applying a map replaces the inferred grid but keeps live loudness', () => {
  const map = buildBeatMap(syntheticHops())
  const live = { ...emptySnapshot(), level: 0.6, energy: 0.7, beatCount: 900, isTempoLocked: false }
  const position = map.beats[70] + 0.1
  const applied = applyBeatMap(live, map, position, 500)
  assert.equal(applied.isTempoLocked, true)
  assert.equal(applied.beatMapActive, true)
  assert.ok(Math.abs(applied.beatReferenceTime - (500 - 0.1)) < 1e-9)
  assert.equal(applied.level, 0.6)
  assert.equal(applied.energy, 0.7)
  assert.equal(applied.gridBeatPosition, applied.beatCount)
  assert.equal(applied.beatInBar, applied.gridBeatPosition % 4)
  assert.ok(applied.barEnergy > 0.5)
  const outside = applyBeatMap(live, map, -3, 500)
  assert.equal(outside.beatMapActive, false)
  assert.equal(outside.barEnergy, undefined)
  assert.equal(outside.beatCount, 900)
})

test('the aligner finds a shifted live envelope and prefers the nearest beat', () => {
  const map = buildBeatMap(syntheticHops())
  const truth = 20, shift = 0.12, seconds = 6
  const n = seconds * ENVELOPE_RATE
  // The live capture is really at truth + shift, while the clock thinks truth.
  const live = Array.from({ length: n }, (_, i) => {
    const index = Math.round((truth + shift - seconds) * ENVELOPE_RATE) + i + 1
    return map.envelope[index] + 0.02 * Math.sin(i * 1.7)
  })
  const result = alignToBeatMap(live, map, truth)
  assert.ok(isTrustworthyAlignment(result), JSON.stringify(result))
  assert.ok(Math.abs(result.offset - shift) <= 0.02, `offset ${result.offset}`)
  const exact = alignToBeatMap(live, map, truth + shift)
  assert.ok(Math.abs(exact.offset) <= 0.02, `exact offset ${exact.offset}`)
  assert.equal(alignToBeatMap(live.slice(0, 50), map, truth), null)
  assert.equal(alignToBeatMap(live.map(() => 0.5), map, truth), null)
})

test('the playback clock dead-reckons, absorbs jitter, re-anchors on seeks and takes nudges', () => {
  const clock = new PlaybackClock()
  assert.equal(clock.report(10, 100, true), 'started')
  assert.ok(Math.abs(clock.positionAt(101.5) - 11.5) < 1e-9)
  assert.equal(clock.report(12.1, 102, true), 'held')
  assert.ok(Math.abs(clock.positionAt(102) - 12.01) < 1e-9, 'a jittered report only nudges the anchor')
  assert.equal(clock.nudge(0.1), true)
  assert.ok(Math.abs(clock.correction - 0.06) < 1e-9)
  assert.equal(clock.nudge(0.005), false)
  assert.equal(clock.nudge(0.5), false)
  assert.equal(clock.report(60, 103, true), 'jumped')
  assert.equal(clock.correction, 0)
  assert.ok(Math.abs(clock.positionAt(104) - 61) < 1e-9)
  assert.equal(clock.report(61, 104, false), 'held')
  assert.ok(Math.abs(clock.positionAt(110) - 61) < 1e-9, 'paused clocks hold still')
})

test('energy tiers follow mapped bars with hysteresis and live bars one bar late', () => {
  const mapped = new EnergyTierTracker()
  assert.equal(mapped.tier, 3)
  assert.equal(mapped.update(0.5, 0.05, 0, 1, 1), 5)
  assert.equal(mapped.update(0.5, 0.05, 0, 1, 0.9), 5, 'inside the hysteresis band')
  assert.equal(mapped.update(0.5, 0.05, 0, 1, 0.85), 4)
  assert.equal(mapped.update(0.5, 0.05, 0, 1, 0.02), 0)

  const live = new EnergyTierTracker()
  let bar = 0, t = 0
  const run = (energy, bars) => {
    for (let frame = 0; frame < bars * 40; frame += 1) { t += 0.05; live.update(energy, 0.05, bar + frame / 40, 1) }
    bar += bars
  }
  run(0.1, 4)
  const quiet = live.tier
  live.update(0.9, 0.05, bar, 1)
  assert.equal(live.tier, quiet, 'the loud bar has not finished yet')
  run(0.9, 2)
  assert.ok(live.tier > quiet, `${live.tier} > ${quiet}`)
})

function engineSnapshot(map, position, timestamp) {
  const live = { ...emptySnapshot(), level: 0.6, energy: 0.6, confidence: 1, analysisTimestamp: timestamp }
  return applyBeatMap(live, map, position, timestamp)
}

function room() {
  return [{ id: 'a', label: 'a', transport: 'lifxLAN', segmentCount: 0, role: 'hit' }]
}

function quietMap(energy) {
  const map = buildBeatMap(syntheticHops({ interval: 0.4, firstBeat: 0.2 }))
  return { ...map, barEnergy: map.barEnergy.map(() => energy) }
}

test('calm music on a fast grid nods every other beat unless the feel is set by hand', () => {
  // Counts where brightness starts to climb: one per felt beat.
  const rises = timeFeel => {
    const map = quietMap(0.2)
    const engine = new MusicChoreographyEngine()
    const config = { ...configurationFor('balanced'), timeFeel, movementAmount: 0, stereoImage: 0 }
    const start = map.beats[map.downbeatOffset + 8]
    const series = []
    for (let step = 0; step < 8 * 8; step += 1) {
      const position = start + step * (0.4 / 8)
      const frame = engine.makeFrame(engineSnapshot(map, position, 1000 + position), config,
        { layout: 'leftToRight', fixtureOrder: [], excludedFixtureIDs: [] }, room(), 1000 + position, step + 1)
      series.push(frame.states[0].brightness)
      assert.equal(frame.energyTier, 1)
    }
    let count = 0
    for (let i = 18; i < series.length; i += 1) {
      if (series[i] - series[i - 1] > 0.015 && series[i - 1] - series[i - 2] <= 0.005) count += 1
    }
    return count
  }
  const auto = rises('auto'), straight = rises('straight')
  assert.ok(auto <= 3, `auto half-time rises ${auto}`)
  assert.ok(straight >= 5, `straight rises ${straight}`)
})

test('high tiers step colour on the beat, low tiers hold it for the bar', () => {
  const huesPerBeat = energy => {
    const map = quietMap(energy)
    const engine = new MusicChoreographyEngine()
    const config = { ...configurationFor('balanced'), movementAmount: 0, stereoImage: 0, colorChangeIntensity: 0.2 }
    const start = map.beats[map.downbeatOffset + 8]
    const hues = []
    for (let step = 0; step < 4 * 16; step += 1) {
      const position = start + step * (0.4 / 16)
      const frame = engine.makeFrame(engineSnapshot(map, position, 2000 + position), config,
        { layout: 'leftToRight', fixtureOrder: [], excludedFixtureIDs: [] }, room(), 2000 + position, step + 1)
      if (step % 16 === 15) hues.push(frame.states[0].hue)
    }
    return new Set(hues.map(hue => hue.toFixed(3))).size
  }
  assert.equal(huesPerBeat(0.3), 1, 'one colour through the bar')
  assert.ok(huesPerBeat(1) >= 3, 'a new colour on most beats')
})

test('the top tier asks for a downbeat flash only through the limiter', () => {
  const flashes = safe => {
    const map = quietMap(1)
    const engine = new MusicChoreographyEngine()
    const config = { ...configurationFor('concert'), photosensitivitySafeMode: safe, percussionSensitivity: 0,
      phraseAware: false, maximumFlashFrequency: 3 }
    const start = map.beats[map.downbeatOffset + 8]
    let count = 0
    for (let step = 0; step < 8 * 16; step += 1) {
      const position = start + step * (0.4 / 16)
      const frame = engine.makeFrame(engineSnapshot(map, position, 3000 + position), config,
        { layout: 'leftToRight', fixtureOrder: [], excludedFixtureIDs: [] }, room(), 3000 + position, step + 1)
      if (frame.flashApplied) count += 1
    }
    return count
  }
  assert.equal(flashes(true), 0)
  assert.equal(flashes(false), 2, 'one per bar across two bars')
})

test('the light timing offset moves the predicted beat by exactly its value', () => {
  const engine = new MusicChoreographyEngine()
  const snapshot = { ...emptySnapshot(), tempo: 120, beatInterval: 0.5, feltInterval: 0.5, beatConfidence: 1,
    beatReferenceTime: 100, isTempoLocked: true, gridBeatPosition: 0 }
  const base = configurationFor('balanced')
  const plain = engine.musicalClock(snapshot, 100.1, base, 0.026, false)
  const early = engine.musicalClock(snapshot, 100.1, { ...base, outputLatencyOffset: 0.1 }, 0.026, false)
  assert.ok(Math.abs(early.phase - plain.phase - 0.2) < 1e-9)
})

test('a decoded file is analysed into a map faster than it plays', async () => {
  const rate = 44100, seconds = 20, frames = rate * seconds
  const data = new Float32Array(frames)
  for (let beat = 0; beat * 0.5 < seconds; beat += 1) {
    const start = Math.round((0.1 + beat * 0.5) * rate)
    const loud = beat % 4 === 0 ? 0.9 : 0.5
    for (let i = 0; i < rate * 0.08 && start + i < frames; i += 1) {
      data[start + i] += loud * Math.sin(2 * Math.PI * 60 * i / rate) * Math.exp(-i / (rate * 0.03))
    }
  }
  const buffer = { numberOfChannels: 1, sampleRate: rate, length: frames, getChannelData: () => data }
  let progress = 0
  const map = await analyzeAudioBuffer(buffer, value => { progress = value })
  assert.equal(progress, 1)
  assert.ok(map, 'map')
  assert.ok(Math.abs(map.tempo - 120) < 2, `tempo ${map.tempo}`)
  const cancelled = await analyzeAudioBuffer(buffer, undefined, () => false)
  assert.equal(cancelled, null)
})

test('taps that land consistently late move the timing earlier by that much', () => {
  const calibrator = new TapCalibrator()
  for (let beat = 0; beat < 7; beat += 1) calibrator.tap(100 + beat * 0.5 + 0.06, 100, 0.5)
  assert.equal(calibrator.suggestedOffset(0), null, 'seven taps are not enough')
  calibrator.tap(100 + 7 * 0.5 + 0.07, 100, 0.5)
  assert.ok(Math.abs(calibrator.lateness - 0.06) < 0.006, `lateness ${calibrator.lateness}`)
  assert.ok(Math.abs(calibrator.suggestedOffset(0.02) - 0.08) < 1e-9)
  assert.equal(calibrator.suggestedOffset(0.28), 0.3)

  const early = new TapCalibrator()
  for (let beat = 0; beat < 8; beat += 1) early.tap(200 + beat * 0.6 - 0.04, 200, 0.6)
  assert.ok(Math.abs(early.suggestedOffset(0) + 0.04) < 1e-9)

  const scattered = new TapCalibrator()
  for (let beat = 0; beat < 10; beat += 1) scattered.tap(300 + beat * 0.5 + (beat % 2 === 0 ? 0.2 : -0.15), 300, 0.5)
  assert.equal(scattered.lateness, null, 'taps all over the beat measure nothing')
  scattered.reset()
  assert.equal(scattered.count, 0)
})

test('the phased build matches the one-shot build and stops when cancelled between phases', async () => {
  const hops = syntheticHops()
  assert.deepEqual(await buildBeatMapAsync(hops), buildBeatMap(hops))
  let checks = 0
  assert.equal(await buildBeatMapAsync(hops, () => ++checks < 3), null)
  assert.equal(checks, 3, 'it checks again after each phase')
})
