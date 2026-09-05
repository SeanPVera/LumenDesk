import { BeatTracker } from "./beat-tracker";
import { RealFFT, hannWindow } from "./fft";
import {
  SPECTRUM_BINS,
  emptySnapshot,
  type AudioReactiveSnapshot,
  type Metre,
  type TimeFeel,
} from "./types";

const WINDOW = 2048;
const HOP = 512;
const LOG_COMPRESSION = 1000;
const MIN_ONSET_SCALE = 0.01;

interface BinRange {
  first: number;
  last: number;
}

export class MusicFeatureAnalyzer {
  sourceDescription: string;
  private readonly fft = new RealFFT(WINDOW);
  private readonly hann = hannWindow(WINDOW);
  private readonly ring = new Float64Array(WINDOW);
  private readonly windowed = new Float64Array(WINDOW);
  private readonly magnitudes = new Float64Array(WINDOW / 2);
  private readonly logMagnitudes = new Float64Array(WINDOW / 2);
  private readonly previousLog = new Float64Array(WINDOW / 2);
  private readonly chroma = new Float64Array(12);
  private readonly spectrum = new Float64Array(SPECTRUM_BINS);
  private ringWrite = 0;
  private samplesUntilHop = HOP;
  private processedSamples = 0;
  private sampleRate = 0;
  private bassBins: BinRange = { first: 1, last: 1 };
  private midsBins: BinRange = { first: 1, last: 1 };
  private highsBins: BinRange = { first: 1, last: 1 };
  private kickBins: BinRange = { first: 1, last: 1 };
  private snareBins: BinRange = { first: 1, last: 1 };
  private hatBins: BinRange = { first: 1, last: 1 };
  private fluxBands: BinRange[] = [];
  private peakLevel = 0.02;
  private bandPeak = 0.0005;
  private odfScale = MIN_ONSET_SCALE;
  private kickScale = MIN_ONSET_SCALE;
  private snareScale = MIN_ONSET_SCALE;
  private hatScale = MIN_ONSET_SCALE;
  private noveltyBaseline = 0;
  private noveltyDeviation = 0;
  private pulseEnv = 0;
  private dropEnv = 0;
  private energyBaseline = 0;
  private leftEnergy = 0;
  private rightEnergy = 0;
  private readonly beatTracker = new BeatTracker();
  private lastSnapshot = emptySnapshot();
  private phraseBars = 0;
  private lastFeltBeat = 0;
  private barEnergies: number[] = [];

  constructor(sourceDescription = "Microphone input") {
    this.sourceDescription = sourceDescription;
  }

  setPolicy(metre: Metre | "auto", feel: TimeFeel): void {
    this.beatTracker.setPolicy(metre, feel);
  }

  reset(sourceDescription?: string): void {
    if (sourceDescription) this.sourceDescription = sourceDescription;
    this.ring.fill(0);
    this.previousLog.fill(0);
    this.spectrum.fill(0);
    this.ringWrite = 0;
    this.samplesUntilHop = HOP;
    this.processedSamples = 0;
    this.pulseEnv = 0;
    this.dropEnv = 0;
    this.energyBaseline = 0;
    this.odfScale = MIN_ONSET_SCALE;
    this.leftEnergy = 0.5;
    this.rightEnergy = 0.5;
    this.beatTracker.reset();
    this.lastSnapshot = emptySnapshot();
    this.phraseBars = 0;
    this.lastFeltBeat = 0;
    this.barEnergies = [];
  }

  analyze(
    samples: ArrayLike<number>,
    hostTime: number,
    stereo?: { left: ArrayLike<number>; right: ArrayLike<number> },
    sampleRate = 48_000,
  ): AudioReactiveSnapshot | null {
    this.configureIfNeeded(sampleRate);
    let latest: AudioReactiveSnapshot | null = null;
    const n = samples.length;
    for (let i = 0; i < n; i += 1) {
      this.ring[this.ringWrite] = samples[i] ?? 0;
      this.ringWrite = (this.ringWrite + 1) % WINDOW;
      this.processedSamples += 1;
      this.samplesUntilHop -= 1;
      if (stereo) {
        const l = Math.abs(stereo.left[i] ?? 0);
        const r = Math.abs(stereo.right[i] ?? 0);
        this.leftEnergy = this.leftEnergy * 0.995 + l * 0.005;
        this.rightEnergy = this.rightEnergy * 0.995 + r * 0.005;
      }
      if (this.samplesUntilHop <= 0) {
        this.samplesUntilHop = HOP;
        latest = this.hop(hostTime);
      }
    }
    return latest;
  }

  private hop(hostTime: number): AudioReactiveSnapshot {
    for (let i = 0; i < WINDOW; i += 1) {
      const index = (this.ringWrite + i) % WINDOW;
      this.windowed[i] = this.ring[index] * this.hann[i];
    }
    this.fft.magnitudes(this.windowed, this.magnitudes);

    for (let i = 0; i < this.logMagnitudes.length; i += 1) {
      this.logMagnitudes[i] = Math.log1p(this.magnitudes[i] * LOG_COMPRESSION);
    }

    const hopDuration = HOP / this.sampleRate;
    let flux = 0;
    for (const band of this.fluxBands) {
      let now = 0;
      let prev = 0;
      for (let i = band.first; i <= band.last; i += 1) {
        now += this.logMagnitudes[i];
        prev += this.previousLog[i];
      }
      flux += Math.max(0, now - prev) / band.last;
    }
    const kickFlux = rectifiedBandFlux(this.logMagnitudes, this.previousLog, this.kickBins);
    const snareFlux = rectifiedBandFlux(this.logMagnitudes, this.previousLog, this.snareBins);
    const hatFlux = rectifiedBandFlux(this.logMagnitudes, this.previousLog, this.hatBins);
    this.previousLog.set(this.logMagnitudes);

    const bass = meanBins(this.magnitudes, this.bassBins);
    const mids = meanBins(this.magnitudes, this.midsBins);
    const highs = meanBins(this.magnitudes, this.highsBins);
    const level = rms(this.windowed);

    this.peakLevel = level > this.peakLevel ? level : this.peakLevel * 0.999;
    this.bandPeak = Math.max(this.bandPeak * 0.999, bass + mids + highs);
    this.odfScale = flux > this.odfScale ? flux : Math.max(MIN_ONSET_SCALE, this.odfScale * 0.9992);
    this.kickScale = kickFlux > this.kickScale ? kickFlux : Math.max(MIN_ONSET_SCALE, this.kickScale * 0.9992);
    this.snareScale = snareFlux > this.snareScale ? snareFlux : Math.max(MIN_ONSET_SCALE, this.snareScale * 0.9992);
    this.hatScale = hatFlux > this.hatScale ? hatFlux : Math.max(MIN_ONSET_SCALE, this.hatScale * 0.9992);

    const onset = Math.max(0, Math.min(1, flux / Math.max(this.odfScale, MIN_ONSET_SCALE)));
    const kick = Math.max(0, Math.min(1, kickFlux / Math.max(this.kickScale, MIN_ONSET_SCALE)));
    const snare = Math.max(0, Math.min(1, snareFlux / Math.max(this.snareScale, MIN_ONSET_SCALE)));
    const percussion = Math.max(0, Math.min(1, hatFlux / Math.max(this.hatScale, MIN_ONSET_SCALE)));

    this.noveltyBaseline = this.noveltyBaseline * 0.98 + onset * 0.02;
    this.noveltyDeviation = this.noveltyDeviation * 0.98 + Math.abs(onset - this.noveltyBaseline) * 0.02;
    const beatSpike = onset > this.noveltyBaseline + this.noveltyDeviation * 1.4 ? onset : 0;

    const sampleTime = this.processedSamples / this.sampleRate;
    const emitted = this.beatTracker.process(onset, kick, sampleTime);
    const grid = this.beatTracker.grid;

    const pulseDecay = grid.isLocked ? Math.min(0.3, Math.max(0.06, grid.feltInterval * 0.12)) : 0.18;
    const pulseAttack = 1 - Math.exp(-hopDuration / 0.02);
    const pulseRelease = 1 - Math.exp(-hopDuration / pulseDecay);
    const pulseTarget = Math.max(beatSpike, grid.isLocked && emitted > 0 ? 1 : 0);
    this.pulseEnv += (pulseTarget - this.pulseEnv) * (pulseTarget > this.pulseEnv ? pulseAttack : pulseRelease);

    const energy = Math.max(
      0,
      Math.min(1, (bass * 0.45 + mids * 0.3 + highs * 0.15 + level * 0.4) / Math.max(0.02, this.peakLevel * 4)),
    );
    this.energyBaseline = this.energyBaseline * 0.995 + energy * 0.005;
    this.dropEnv = energy > 0.7 ? Math.min(1, this.dropEnv + hopDuration * 0.7) : Math.max(0, this.dropEnv - hopDuration * 0.5);

    this.updateChroma();
    this.updateSpectrum();
    const stereoDenom = this.leftEnergy + this.rightEnergy;
    const stereo = stereoDenom <= 1e-6 ? 0.5 : this.rightEnergy / stereoDenom;

    if (grid.beatCount !== this.lastFeltBeat) {
      this.lastFeltBeat = grid.beatCount;
      const feltEvery = grid.timeFeel === "half" ? 2 : 1;
      if (grid.beatCount % Math.max(1, feltEvery) === 0 && grid.beatInBar === 0) {
        this.phraseBars += 1;
        this.barEnergies.push(energy);
        if (this.barEnergies.length > 8) this.barEnergies.shift();
      }
    }
    const slope = energySlope(this.barEnergies);

    const snapshot: AudioReactiveSnapshot = {
      level: Math.max(0, Math.min(1, level / Math.max(0.02, this.peakLevel))),
      beat: emitted > 0 ? Math.max(kick, beatSpike) : 0,
      kick,
      snare,
      percussion,
      bass: Math.max(0, Math.min(1, bass / Math.max(this.bandPeak, 1e-6))),
      mids: Math.max(0, Math.min(1, mids / Math.max(this.bandPeak, 1e-6))),
      highs: Math.max(0, Math.min(1, highs / Math.max(this.bandPeak, 1e-6))),
      energy,
      mood: Math.max(0, Math.min(1, 0.35 + highs * 0.4 + mids * 0.2)),
      confidence: Math.max(onset, grid.confidence),
      pulse: this.pulseEnv,
      drop: this.dropEnv,
      beatCount: grid.beatCount,
      tempo: grid.tempo,
      beatInterval: grid.interval,
      beatConfidence: grid.confidence,
      beatReferenceTime: hostTime - (sampleTime - grid.lastBeatTime),
      beatInBar: grid.beatInBar,
      isTempoLocked: grid.isLocked,
      metre: grid.metre,
      metreConfidence: grid.metreConfidence,
      timeFeel: grid.timeFeel,
      feltInterval: grid.feltInterval,
      feltTempo: grid.feltTempo,
      stereo,
      chroma: Array.from(this.chroma),
      spectrum: Array.from(this.spectrum),
      phrasePosition: this.phraseBars % 8,
      energySlope: slope,
      sourceDescription: this.sourceDescription,
    };
    this.lastSnapshot = snapshot;
    return snapshot;
  }

  latest(): AudioReactiveSnapshot {
    return this.lastSnapshot;
  }

  private updateSpectrum(): void {
    const n = this.magnitudes.length;
    const peak = Math.max(this.bandPeak, 1e-6);
    for (let i = 0; i < SPECTRUM_BINS; i += 1) {
      const a = Math.floor(((i / SPECTRUM_BINS) ** 2) * (n - 2)) + 1;
      const b = Math.floor((((i + 1) / SPECTRUM_BINS) ** 2) * (n - 2)) + 1;
      let sum = 0;
      const last = Math.max(a + 1, b);
      for (let k = a; k < last && k < n; k += 1) sum += this.magnitudes[k];
      const mean = sum / Math.max(1, last - a);
      const target = Math.min(1, mean / peak);
      this.spectrum[i] = this.spectrum[i] * 0.55 + target * 0.45;
    }
  }

  private updateChroma(): void {
    this.chroma.fill(0);
    const sr = this.sampleRate;
    for (let bin = 2; bin < this.magnitudes.length; bin += 1) {
      const freq = (bin * sr) / WINDOW;
      if (freq < 55 || freq > 2000) continue;
      const midi = 69 + 12 * Math.log2(freq / 440);
      const pc = ((Math.round(midi) % 12) + 12) % 12;
      this.chroma[pc] += this.magnitudes[bin];
    }
    let max = 0;
    for (let i = 0; i < 12; i += 1) max = Math.max(max, this.chroma[i]);
    if (max > 0) {
      for (let i = 0; i < 12; i += 1) this.chroma[i] /= max;
    }
  }

  private configureIfNeeded(sampleRate: number): void {
    if (this.sampleRate === sampleRate) return;
    this.sampleRate = sampleRate;
    this.beatTracker.configure(HOP / sampleRate);
    this.bassBins = binsFor(sampleRate, 20, 140);
    this.midsBins = binsFor(sampleRate, 140, 1600);
    this.highsBins = binsFor(sampleRate, 1600, 8000);
    this.kickBins = binsFor(sampleRate, 30, 120);
    this.snareBins = binsFor(sampleRate, 180, 420);
    this.hatBins = binsFor(sampleRate, 5000, 12000);
    this.fluxBands = logBands(sampleRate, 8);
  }
}

function binsFor(sampleRate: number, low: number, high: number): BinRange {
  const hz = sampleRate / WINDOW;
  const first = Math.max(1, Math.floor(low / hz));
  const last = Math.min(WINDOW / 2 - 1, Math.ceil(high / hz));
  return { first, last: Math.max(first, last) };
}

function logBands(sampleRate: number, count: number): BinRange[] {
  const min = 30;
  const max = Math.min(sampleRate / 2 - 1, 12_000);
  const bands: BinRange[] = [];
  for (let i = 0; i < count; i += 1) {
    const a = min * Math.pow(max / min, i / count);
    const b = min * Math.pow(max / min, (i + 1) / count);
    bands.push(binsFor(sampleRate, a, b));
  }
  return bands;
}

function meanBins(magnitudes: Float64Array, range: BinRange): number {
  let sum = 0;
  for (let i = range.first; i <= range.last; i += 1) sum += magnitudes[i];
  return sum / Math.max(1, range.last - range.first + 1);
}

function rectifiedBandFlux(now: Float64Array, prev: Float64Array, range: BinRange): number {
  let sum = 0;
  for (let i = range.first; i <= range.last; i += 1) sum += Math.max(0, now[i] - prev[i]);
  return sum / Math.max(1, range.last - range.first + 1);
}

function rms(samples: Float64Array): number {
  let sum = 0;
  for (let i = 0; i < samples.length; i += 1) sum += samples[i] * samples[i];
  return Math.sqrt(sum / samples.length);
}

function energySlope(bars: number[]): number {
  if (bars.length < 3) return 0;
  const n = bars.length;
  let sumX = 0;
  let sumY = 0;
  let sumXY = 0;
  let sumXX = 0;
  for (let i = 0; i < n; i += 1) {
    sumX += i;
    sumY += bars[i];
    sumXY += i * bars[i];
    sumXX += i * i;
  }
  const denom = n * sumXX - sumX * sumX;
  if (Math.abs(denom) < 1e-6) return 0;
  return Math.max(-1, Math.min(1, (n * sumXY - sumX * sumY) / denom));
}
