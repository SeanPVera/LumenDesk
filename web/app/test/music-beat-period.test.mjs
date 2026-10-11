import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MusicFeatureAnalyzer } from '../.test-build/analyzer.js'
import { BeatTracker } from '../.test-build/beat-tracker.js'

test('fractional beat periods keep phase aligned after the history wraps', () => {
  for (const bpm of [90, 137, 150, 180, 200]) {
    for (const rate of [44100, 48000]) {
      for (const hasKick of [false, true]) {
        const dt = 512 / rate, period = 60 / bpm, offset = .093
        const tracker = new BeatTracker(dt)
        let error = 0, observed = 0
        for (let frame = 0; frame < 18 / dt; frame++) {
          const time = frame * dt
          const phase = ((time - offset) % period + period) % period
          const onset = Math.max(0, 1 - Math.min(phase, period - phase) / .025)
          tracker.process(onset, hasKick ? onset : 0, time)
          if (time <= 12 || !tracker.grid.isLocked) continue
          const beatPhase = ((tracker.grid.lastBeatTime - offset) % period + period) % period
          error += Math.min(beatPhase, period - beatPhase)
          observed++
        }
        assert.ok(observed > 400, `${bpm} BPM at ${rate} Hz did not remain locked`)
        assert.ok(error / observed < .003, `${bpm} BPM at ${rate} Hz, kick=${hasKick}: ${error / observed * 1000} ms phase error`)
      }
    }
  }
})

// Kick and sixteenth-note hi-hat PCM expose harmonic alignment errors that a
// synthetic onset train does not: 150 BPM is 37.5 analysis hops at 48 kHz.
for (const bpm of [60, 90, 150, 180, 200]) {
  test(`PCM at ${bpm} BPM keeps the measured pulse rather than its octave`, () => {
    for (const rate of [44100, 48000]) {
      for (const attack of bpm === 60 || bpm === 90 ? [.002] : [.0005, .002, .01]) {
        const duration = 16, offset = .093, period = 60 / bpm, total = duration * rate
        const samples = Float32Array.from({ length: total }, (_, i) => {
          const t = i / rate
          const kickPhase = ((t - offset) % period + period) % period
          const hatPeriod = period / 4
          const hatPhase = ((t - offset) % hatPeriod + hatPeriod) % hatPeriod
          return .7 * Math.sin(2 * Math.PI * 65 * t) * Math.exp(-kickPhase / .045) * (1 - Math.exp(-kickPhase / attack))
            + .18 * Math.sin(2 * Math.PI * 8000 * t) * Math.exp(-hatPhase / .012) * (1 - Math.exp(-hatPhase / .0005))
        })
        const analyzer = new MusicFeatureAnalyzer()
        const chunk = rate === 44100 ? 512 : 1024
        let correct = 0, observed = 0, lastBeat = -1
        const phases = []
        for (let start = 0; start < total; start += chunk) {
          const end = Math.min(total, start + chunk)
          const snapshot = analyzer.analyze(samples.subarray(start, end), 100 + end / rate, undefined, rate)
          if (!snapshot || end / rate < 10) continue
          observed++
          if (snapshot.isTempoLocked && Math.abs(snapshot.tempo - bpm) < 6) correct++
          if (snapshot.isTempoLocked && snapshot.gridBeatPosition !== lastBeat) {
            const reference = snapshot.beatReferenceTime - 100 - offset
            phases.push(reference - Math.round(reference / period) * period)
            lastBeat = snapshot.gridBeatPosition
          }
        }
        assert.ok(correct / observed > .99, `${bpm} BPM, ${rate} Hz, ${attack * 1000} ms attack: ${correct}/${observed}, final ${analyzer.latest().tempo}`)
        if (bpm === 60) assert.ok(Math.abs(analyzer.latest().tempo - bpm) < .3)
        else assert.equal(analyzer.latest().timeFeel, 'straight')
        if (bpm === 90 && rate === 48000) {
          // Whole-hop phase combs jumped around as the same fractional pulse
          // crossed successive FFT windows, despite a correct tempo estimate.
          assert.ok(phases.length >= 8)
          assert.ok(Math.max(...phases) - Math.min(...phases) < .006)
        }
      }
    }
  })
}
