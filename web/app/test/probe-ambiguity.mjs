// Characterization, not a passing musical-accuracy assertion. Uses the shipped
// web analyzer directly. Keep failures visible when changing the tempo search.
import { MusicFeatureAnalyzer } from '../.test-build/analyzer.js'
for (const mode of ['syncopated', 'half', 'waltz']) {
  const analyzer = new MusicFeatureAnalyzer(mode), rate = 48000
  let latest, locked = 0, total = 0
  for (let offset = 0; offset < rate * 24; offset += 1024) {
    const pcm = Float32Array.from({ length: 1024 }, (_, i) => {
      const t = (offset + i) / rate, phase = t * 2, bar = phase % 4, h = (phase * 4) % 1
      const k = mode === 'half' ? bar : mode === 'waltz' ? phase % 1 : bar >= 2.5 ? bar - 2.5 : bar >= 1.5 ? bar - 1.5 : bar
      const sn = (phase + (mode === 'half' ? 2 : 1)) % (mode === 'half' ? 4 : 2)
      const strength = mode === 'waltz' && Math.floor(phase) % 3 !== 0 ? .25 : .7
      return strength * Math.sin(2 * Math.PI * 65 * t) * Math.exp(-k / .09) * (1 - Math.exp(-k / .004))
        + (mode === 'waltz' ? 0 : .3) * Math.sin(2 * Math.PI * 1800 * t) * Math.exp(-sn / .07) * (1 - Math.exp(-sn / .002))
        + .09 * Math.sin(2 * Math.PI * 8000 * t) * Math.exp(-h / .096) * (1 - Math.exp(-h / .004))
    })
    const t = (offset + 1024) / rate, s = analyzer.analyze(pcm, 100 + t, undefined, rate)
    if (s && t > 16) { latest = s; total++; if (s.isTempoLocked) locked++ }
  }
  console.log(JSON.stringify({ probe: mode, intendedGrid: 120, locked, total, tempo: latest.tempo,
    confidence: latest.beatConfidence, metre: latest.metre, feel: latest.timeFeel }))
}
