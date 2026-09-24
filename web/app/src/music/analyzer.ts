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
  private beatCount = 0;
  private cooldown = 0;
  private lastBufferEnd: number | null = null;
  private hostOffset = 0;
  private hasHostAnchor = false;
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
  private readonly beatTracker = new BeatTracker();
  private lastSnapshot = emptySnapshot();

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
    this.kickScale = this.snareScale = this.hatScale = MIN_ONSET_SCALE;
    this.bandPeak = .0005; this.noveltyBaseline = this.noveltyDeviation = 0;
    this.cooldown = 0; this.lastBufferEnd = null; this.hasHostAnchor = false;
    this.hostOffset = 0;
    this.beatTracker.reset();
    this.lastSnapshot = emptySnapshot();
  }

  analyze(
    samples: ArrayLike<number>,
    hostTime: number,
    stereo?: { left: ArrayLike<number>; right: ArrayLike<number> },
    sampleRate = 48_000,
  ): AudioReactiveSnapshot | null {
    if (!Number.isFinite(sampleRate) || sampleRate <= 0 || samples.length === 0) return null;
    if (this.sampleRate && sampleRate !== this.sampleRate) this.reset();
    if (this.lastBufferEnd != null) {
      if (hostTime <= this.lastBufferEnd) return null;
      if (Math.abs(hostTime - this.lastBufferEnd - samples.length / sampleRate) > .03) this.reset();
    }
    this.lastBufferEnd = hostTime;
    this.configureIfNeeded(sampleRate);
    const target = hostTime - (this.processedSamples + samples.length) / sampleRate;
    this.hostOffset = this.hasHostAnchor ? this.hostOffset + (target - this.hostOffset) * .05 : target;
    this.hasHostAnchor = true;
    let latest: AudioReactiveSnapshot | null = null;
    let strongestBeat = 0;
    let left = 0, right = 0;
    for (let i = 0; i < samples.length; i++) {
      const l = stereo?.left[i] ?? samples[i] ?? 0;
      const r = stereo?.right[i] ?? l;
      left += l * l; right += r * r;
    }
    left = Math.sqrt(left / samples.length); right = Math.sqrt(right / samples.length);
    const image = left + right < 1e-8 ? .5 : right / (left + right);
    for (let i = 0; i < samples.length; i++) {
      this.ring[this.ringWrite] = stereo ? ((stereo.left[i] ?? 0) + (stereo.right[i] ?? 0)) / 2 : samples[i] ?? 0;
      this.ringWrite = (this.ringWrite + 1) % WINDOW;
      this.processedSamples++;
      if (--this.samplesUntilHop <= 0) {
        this.samplesUntilHop = HOP;
        latest = this.hop(image);
        strongestBeat = Math.max(strongestBeat, latest.beat);
      }
    }
    if (latest) { latest.beat = strongestBeat; this.lastSnapshot = latest; }
    return latest;
  }

  private hop(stereo: number): AudioReactiveSnapshot {
    let square = 0;
    for (let i = 0; i < WINDOW; i++) {
      const sample = this.ring[(this.ringWrite + i) % WINDOW];
      square += sample * sample;
      this.windowed[i] = sample * this.hann[i];
    }
    const rms = Math.sqrt(square / WINDOW);
    const level = clamp(Math.log1p(Math.max(0, rms - .001) * 20) / Math.log1p(10));
    this.fft.magnitudes(this.windowed, this.magnitudes);
    for (let i = 1; i < this.logMagnitudes.length; i++) this.logMagnitudes[i] = Math.log1p(this.magnitudes[i] * LOG_COMPRESSION);
    const dt = HOP / this.sampleRate;
    const bassRaw = meanBins(this.magnitudes, this.bassBins);
    const midsRaw = meanBins(this.magnitudes, this.midsBins);
    const highsRaw = meanBins(this.magnitudes, this.highsBins);
    const loudest = Math.max(bassRaw, midsRaw, highsRaw);
    this.bandPeak = loudest > this.bandPeak ? this.bandPeak + (loudest - this.bandPeak) * .3 : Math.max(.00002, this.bandPeak * Math.exp(-dt / 8));
    const scale = .9 / this.bandPeak * Math.sqrt(level);
    const bass = clamp(bassRaw * scale), mids = clamp(midsRaw * scale), highs = clamp(highsRaw * scale);
    const flux = this.fluxBands.reduce((n,b)=>n+rectifiedBandFlux(this.logMagnitudes,this.previousLog,b),0) / Math.max(1,this.fluxBands.length);
    const rawKick = rectifiedBandFlux(this.logMagnitudes,this.previousLog,this.kickBins);
    const rawSnare = rectifiedBandFlux(this.logMagnitudes,this.previousLog,this.snareBins);
    const rawHat = rectifiedBandFlux(this.logMagnitudes,this.previousLog,this.hatBins);
    this.previousLog.set(this.logMagnitudes);
    const normalize = (value: number, key: 'odfScale'|'kickScale'|'snareScale'|'hatScale') => {
      this[key] = value > this[key] ? this[key] + (value - this[key]) * .3 : Math.max(MIN_ONSET_SCALE, this[key] * Math.exp(-dt / 6));
      return clamp(value / this[key] * .9);
    };
    const onset = normalize(flux,'odfScale'), kick = normalize(rawKick,'kickScale');
    const snare = normalize(rawSnare,'snareScale'), percussion = normalize(rawHat,'hatScale');
    const energy = clamp(level * .4 + bass * .3 + mids * .16 + highs * .14);
    const sampleTime = this.processedSamples / this.sampleRate;
    const beatOnset = clamp(onset * .6 + kick * .4);
    const emitted = this.beatTracker.process(beatOnset, kick, sampleTime);
    const grid = this.beatTracker.grid;
    const coefficient = 1 - Math.exp(-dt / 1.5);
    this.noveltyBaseline += (beatOnset - this.noveltyBaseline) * coefficient;
    this.noveltyDeviation += (Math.abs(beatOnset-this.noveltyBaseline)-this.noveltyDeviation)*coefficient;
    let beat = 0;
    if (grid.isLocked) {
      if (emitted > 0) { this.beatCount += emitted; beat = clamp(.6 + onset * .4); }
    } else if (beatOnset > this.noveltyBaseline + Math.max(.09,this.noveltyDeviation*2.2) && beatOnset > .18 && this.cooldown <= 0) {
      this.beatCount++; this.cooldown = .16; beat = clamp(.5+beatOnset*.5);
    }
    this.cooldown = Math.max(0,this.cooldown-dt);
    const decay = grid.isLocked ? Math.min(.34,Math.max(.1,grid.interval*.42)) : .16;
    this.pulseEnv = Math.max(this.pulseEnv*Math.exp(-dt/decay),onset*.85,beat > 0 ? .9 : 0);
    this.energyBaseline += (energy-this.energyBaseline)*(1-Math.exp(-dt/3.3));
    this.dropEnv = Math.max(this.dropEnv*Math.exp(-dt/.3),clamp((energy-.5)*2.4)*clamp((energy-this.energyBaseline)*4+.3));
    this.updateChroma(); this.updateSpectrum();
    return {...emptySnapshot(),level,beat,kick,snare,percussion,bass,mids,highs,energy,
      mood:clamp(.5+(highs-bass)*.6+mids*.05), confidence:clamp(level*1.8),pulse:clamp(this.pulseEnv),drop:clamp(this.dropEnv),
      beatCount:this.beatCount,tempo:grid.isLocked?grid.tempo:0,beatInterval:grid.isLocked?grid.interval:0,
      beatConfidence:grid.confidence,beatReferenceTime:grid.lastBeatTime>0?grid.lastBeatTime+this.hostOffset:0,
      beatInBar:grid.beatInBar,isTempoLocked:grid.isLocked,metre:grid.metre,metreConfidence:grid.metreConfidence,
      timeFeel:grid.timeFeel,feltInterval:grid.isLocked?grid.feltInterval:0,feltTempo:grid.isLocked?grid.feltTempo:0,
      stereo,chroma:Array.from(this.chroma),spectrum:Array.from(this.spectrum),
      phrasePosition:Math.floor(this.beatCount/grid.metre)%8,energySlope:energy-this.lastSnapshot.energy,
      sourceDescription:this.sourceDescription,analysisTimestamp:sampleTime+this.hostOffset,
      rawRMS:rms,onset,gridBeatPosition:grid.beatCount,analyzedSamples:this.processedSamples};
  }

  latest(): AudioReactiveSnapshot { return this.lastSnapshot; }

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
    this.bassBins = binsFor(sampleRate, 45, 160);
    this.midsBins = binsFor(sampleRate, 350, 2200);
    this.highsBins = binsFor(sampleRate, 3200, 12000);
    this.kickBins = binsFor(sampleRate, 40, 150);
    this.snareBins = binsFor(sampleRate, 200, 2000);
    this.hatBins = binsFor(sampleRate, 3000, 12000);
    this.fluxBands = logBands(sampleRate, 24);
  }
}

function binsFor(sampleRate: number, low: number, high: number): BinRange {
  const hz = sampleRate / WINDOW;
  const first = Math.min(WINDOW / 2 - 1, Math.max(1, Math.ceil(low / hz)));
  const last = Math.min(WINDOW / 2 - 1, Math.floor(high / hz));
  return { first, last: Math.max(first, last) };
}

function logBands(sampleRate: number, count: number): BinRange[] {
  const min = 40;
  const max = Math.min(sampleRate / 2 - 1, 16_000);
  const bands: BinRange[] = [];
  for (let i = 0; i < count; i += 1) {
    const a = min * Math.pow(max / min, i / count);
    const b = min * Math.pow(max / min, (i + 1) / count);
    const band = binsFor(sampleRate,a,b);
    const last = bands.at(-1);
    if (!last || last.first !== band.first || last.last !== band.last) bands.push(band);
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

function clamp(value: number): number { return Math.max(0,Math.min(1,value)); }
