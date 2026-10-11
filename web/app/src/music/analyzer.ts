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
// WINDOW is a power of two, so a mask wraps its bounded write index.
const WINDOW_MASK = WINDOW - 1;
const HOP = 512;
const LOG_COMPRESSION = 1000;
const MIN_ONSET_SCALE = 0.01;

interface BinRange {
  first: number;
  last: number;
}

/** Half-open magnitude-bin span behind each display bar; squared so low frequencies get more bars. */
const SPECTRUM_RANGES: { first: number; end: number }[] = (() => {
  const n = WINDOW / 2;
  const ranges: { first: number; end: number }[] = [];
  for (let i = 0; i < SPECTRUM_BINS; i += 1) {
    const first = Math.floor(((i / SPECTRUM_BINS) ** 2) * (n - 2)) + 1;
    const next = Math.floor((((i + 1) / SPECTRUM_BINS) ** 2) * (n - 2)) + 1;
    ranges.push({ first, end: Math.max(first + 1, next) });
  }
  return ranges;
})();

export class MusicFeatureAnalyzer {
  sourceDescription: string;
  private readonly fft = new RealFFT(WINDOW);
  private readonly hann = hannWindow(WINDOW);
  /** One ring per channel. A packed FFT averages their power: an (L + R) / 2
   * waveform downmix lets opposite-phase or wide material cancel out. */
  private readonly rings = [new Float64Array(WINDOW), new Float64Array(WINDOW)];
  private channels = 0;
  private readonly windowed = [new Float64Array(WINDOW), new Float64Array(WINDOW)];
  private readonly magnitudes = new Float64Array(WINDOW / 2);
  /** Hops left before the ring holds a whole window again. Until then a hop
   * compares a partly empty window with an emptier one, which reads as a
   * full-strength onset and inflates the onset gain for seconds. */
  private warmupHops = WINDOW / HOP;
  private logMagnitudes = new Float64Array(WINDOW / 2);
  private previousLog = new Float64Array(WINDOW / 2);
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
  private lastFluxBin = WINDOW / 2 - 1;
  private frameInterval = 0;
  private bandPeakDecay = 0;
  private onsetScaleDecay = 0;
  private noveltyCoefficient = 0;
  private energyCoefficient = 0;
  private dropDecay = 0;
  private transientDecay = 0;
  private chromaBins: BinRange = { first: 1, last: 0 };
  private readonly chromaPitchClass = new Uint8Array(WINDOW / 2);
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
  /** Reused hop scalars; only the published buffer snapshot owns arrays. */
  private hopSnapshot = emptySnapshot();
  private lastSnapshot = emptySnapshot();

  constructor(sourceDescription = "Microphone input") {
    this.sourceDescription = sourceDescription;
  }

  setPolicy(metre: Metre | "auto", feel: TimeFeel): void {
    this.beatTracker.setPolicy(metre, feel);
  }

  reset(sourceDescription?: string): void {
    if (sourceDescription) this.sourceDescription = sourceDescription;
    for (const ring of this.rings) ring.fill(0);
    this.warmupHops = WINDOW / HOP;
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
    this.hopSnapshot = emptySnapshot();
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
    const channels = stereo ? 2 : 1;
    if (channels !== this.channels) {
      // Windows of a different channel layout cannot be compared.
      if (this.channels) this.reset();
      this.channels = channels;
    }
    if (this.lastBufferEnd != null) {
      if (hostTime <= this.lastBufferEnd) return null;
      if (Math.abs(hostTime - this.lastBufferEnd - samples.length / sampleRate) > .03) this.reset();
    }
    this.lastBufferEnd = hostTime;
    this.configureIfNeeded(sampleRate);
    const target = hostTime - (this.processedSamples + samples.length) / sampleRate;
    this.hostOffset = this.hasHostAnchor ? this.hostOffset + (target - this.hostOffset) * .05 : target;
    this.hasHostAnchor = true;
    let didHop = false;
    let strongestBeat = 0;
    let strongestKick = 0, strongestSnare = 0, strongestPercussion = 0, strongestOnset = 0;
    let left = 0, right = 0;
    const leftRing = this.rings[0], rightRing = this.rings[1];
    // Copy spans that end at a hop or ring boundary. The inner sample loops
    // need neither a modulo nor a hop branch, including uneven input buffers.
    let offset = 0;
    while (offset < samples.length) {
      const count = Math.min(this.samplesUntilHop, samples.length - offset, WINDOW - this.ringWrite);
      if (stereo) {
        const stereoLeft = stereo.left, stereoRight = stereo.right;
        for (let i = 0; i < count; i++) {
          const inputIndex = offset + i;
          const channelLeft = stereoLeft[inputIndex], channelRight = stereoRight[inputIndex];
          const l = channelLeft ?? samples[inputIndex] ?? 0;
          const r = channelRight ?? l;
          left += l * l; right += r * r;
          // Preserve image fallbacks without inventing energy in a missing
          // capture channel: absent channel samples are silence for analysis.
          leftRing[this.ringWrite + i] = channelLeft ?? 0;
          rightRing[this.ringWrite + i] = channelRight ?? 0;
        }
      } else {
        for (let i = 0; i < count; i++) {
          const l = samples[offset + i] ?? 0;
          left += l * l;
          leftRing[this.ringWrite + i] = l;
        }
      }
      offset += count;
      this.ringWrite = (this.ringWrite + count) & WINDOW_MASK;
      this.processedSamples += count;
      this.samplesUntilHop -= count;
      if (this.samplesUntilHop === 0) {
        this.samplesUntilHop = HOP;
        this.hop();
        didHop = true;
        // A capture buffer can contain several hops. Retain early hits at
        // their age in the final snapshot instead of dropping them or moving
        // an undiminished hit to the time of the last hop.
        const decay = this.transientDecay;
        strongestBeat = Math.max(strongestBeat * decay, this.hopSnapshot.beat);
        strongestKick = Math.max(strongestKick * decay, this.hopSnapshot.kick);
        strongestSnare = Math.max(strongestSnare * decay, this.hopSnapshot.snare);
        strongestPercussion = Math.max(strongestPercussion * decay, this.hopSnapshot.percussion);
        strongestOnset = Math.max(strongestOnset * decay, this.hopSnapshot.onset ?? 0);
      }
    }
    if (!didHop) return null;
    if (!stereo) right = left;
    left = Math.sqrt(left / samples.length); right = Math.sqrt(right / samples.length);
    const image = left + right < 1e-8 ? .5 : right / (left + right);
    // Chroma is a view of the final window, not an input to onset tracking.
    this.updateChroma();
    this.lastSnapshot = {...this.hopSnapshot, beat: strongestBeat, kick: strongestKick,
      snare: strongestSnare, percussion: strongestPercussion, onset: strongestOnset, stereo: image,
      chroma: Array.from(this.chroma), spectrum: Array.from(this.spectrum)};
    return this.lastSnapshot;
  }

  /** Fills `windowed` from a channel's ring and returns its mean square. */
  private windowChannel(ring: Float64Array, windowed: Float64Array): number {
    let square = 0;
    // The ring is two contiguous spans in chronological order.
    const write = this.ringWrite, hann = this.hann;
    const firstLength = WINDOW - write;
    for (let i = 0; i < firstLength; i++) {
      const sample = ring[write + i];
      square += sample * sample;
      windowed[i] = sample * hann[i];
    }
    for (let i = firstLength; i < WINDOW; i++) {
      const sample = ring[i - firstLength];
      square += sample * sample;
      windowed[i] = sample * hann[i];
    }
    return square / WINDOW;
  }

  private hop(): void {
    let meanSquare = this.windowChannel(this.rings[0], this.windowed[0]);
    if (this.channels > 1) {
      meanSquare = (meanSquare + this.windowChannel(this.rings[1], this.windowed[1])) / 2;
    }
    if (meanSquare === 0) {
      // Only exact digital silence takes this path: quiet signals still get
      // their complete FFT and every hop still advances decay and beat state.
      this.magnitudes.fill(0);
      this.logMagnitudes.fill(0);
    } else if (this.channels <= 1) {
      this.fft.magnitudes(this.windowed[0], this.magnitudes);
    } else {
      // Average channel POWER, not waveforms, so opposite phase cannot cancel.
      this.fft.stereoMagnitudes(this.windowed[0], this.windowed[1], this.magnitudes);
    }
    const rms = Math.sqrt(meanSquare);
    const level = clamp(Math.log1p(Math.max(0, rms - .001) * 20) / Math.log1p(10));
    if (meanSquare > 0) {
      // Display and pitch features consume linear magnitudes. Only onset
      // bands need logarithms, so bins above their upper edge are unused.
      for (let i = 1; i <= this.lastFluxBin; i++) this.logMagnitudes[i] = Math.log1p(this.magnitudes[i] * LOG_COMPRESSION);
    }
    const dt = this.frameInterval;
    const bassRaw = meanBins(this.magnitudes, this.bassBins);
    const midsRaw = meanBins(this.magnitudes, this.midsBins);
    const highsRaw = meanBins(this.magnitudes, this.highsBins);
    const loudest = Math.max(bassRaw, midsRaw, highsRaw);
    this.bandPeak = loudest > this.bandPeak ? this.bandPeak + (loudest - this.bandPeak) * .3 : Math.max(.00002, this.bandPeak * this.bandPeakDecay);
    const scale = .9 / this.bandPeak * Math.sqrt(level);
    const bass = clamp(bassRaw * scale), mids = clamp(midsRaw * scale), highs = clamp(highsRaw * scale);
    let flux = 0, rawKick = 0, rawSnare = 0, rawHat = 0;
    if (this.warmupHops > 0) {
      this.warmupHops -= 1;
    } else {
      let fluxSum = 0;
      for (const band of this.fluxBands) fluxSum += rectifiedBandFlux(this.logMagnitudes,this.previousLog,band);
      flux = fluxSum / Math.max(1,this.fluxBands.length);
      rawKick = rectifiedBandFlux(this.logMagnitudes,this.previousLog,this.kickBins);
      rawSnare = rectifiedBandFlux(this.logMagnitudes,this.previousLog,this.snareBins);
      rawHat = rectifiedBandFlux(this.logMagnitudes,this.previousLog,this.hatBins);
    }
    const previousLog = this.previousLog;
    this.previousLog = this.logMagnitudes;
    this.logMagnitudes = previousLog;
    this.odfScale = updatedOnsetScale(this.odfScale, flux, this.onsetScaleDecay);
    this.kickScale = updatedOnsetScale(this.kickScale, rawKick, this.onsetScaleDecay);
    this.snareScale = updatedOnsetScale(this.snareScale, rawSnare, this.onsetScaleDecay);
    this.hatScale = updatedOnsetScale(this.hatScale, rawHat, this.onsetScaleDecay);
    const onset = clamp(flux / this.odfScale * .9), kick = clamp(rawKick / this.kickScale * .9);
    const snare = clamp(rawSnare / this.snareScale * .9), percussion = clamp(rawHat / this.hatScale * .9);
    const energy = clamp(level * .4 + bass * .3 + mids * .16 + highs * .14);
    const sampleTime = this.processedSamples / this.sampleRate;
    const beatOnset = clamp(onset * .6 + kick * .4);
    const emitted = this.beatTracker.process(beatOnset, kick, sampleTime);
    const grid = this.beatTracker.grid;
    const coefficient = this.noveltyCoefficient;
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
    this.energyBaseline += (energy-this.energyBaseline)*this.energyCoefficient;
    this.dropEnv = Math.max(this.dropEnv*this.dropDecay,clamp((energy-.5)*2.4)*clamp((energy-this.energyBaseline)*4+.3));
    // Spectrum smoothing still sees every hop, including intermediate ones.
    this.updateSpectrum();
    const s = this.hopSnapshot;
    s.level = level; s.beat = beat; s.kick = kick; s.snare = snare;
    s.percussion = percussion; s.bass = bass; s.mids = mids; s.highs = highs;
    s.energy = energy; s.mood = clamp(.5+(highs-bass)*.6+mids*.05);
    s.confidence = clamp(level*1.8); s.pulse = clamp(this.pulseEnv); s.drop = clamp(this.dropEnv);
    s.beatCount = this.beatCount; s.tempo = grid.isLocked ? grid.tempo : 0;
    s.beatInterval = grid.isLocked ? grid.interval : 0; s.beatConfidence = grid.confidence;
    s.beatReferenceTime = grid.lastBeatTime > 0 ? grid.lastBeatTime+this.hostOffset : 0;
    s.beatInBar = grid.beatInBar; s.isTempoLocked = grid.isLocked; s.metre = grid.metre;
    s.metreConfidence = grid.metreConfidence; s.timeFeel = grid.timeFeel;
    s.feltInterval = grid.isLocked ? grid.feltInterval : 0; s.feltTempo = grid.isLocked ? grid.feltTempo : 0;
    s.phrasePosition = Math.floor(this.beatCount/grid.metre)%8;
    s.energySlope = energy-this.lastSnapshot.energy; s.sourceDescription = this.sourceDescription;
    s.analysisTimestamp = sampleTime+this.hostOffset; s.rawRMS = rms; s.onset = onset;
    s.gridBeatPosition = grid.beatCount; s.analyzedSamples = this.processedSamples;
  }

  latest(): AudioReactiveSnapshot { return this.lastSnapshot; }

  private updateSpectrum(): void {
    const magnitudes = this.magnitudes, spectrum = this.spectrum;
    const n = magnitudes.length;
    const peak = Math.max(this.bandPeak, 1e-6);
    for (let i = 0; i < SPECTRUM_BINS; i += 1) {
      const { first, end } = SPECTRUM_RANGES[i];
      let sum = 0;
      for (let k = first; k < end && k < n; k += 1) sum += magnitudes[k];
      const mean = sum / (end - first);
      const target = Math.min(1, mean / peak);
      spectrum[i] = spectrum[i] * 0.55 + target * 0.45;
    }
  }

  private updateChroma(): void {
    const chroma = this.chroma, magnitudes = this.magnitudes, pitchClass = this.chromaPitchClass;
    chroma.fill(0);
    const { first, last } = this.chromaBins;
    for (let bin = first; bin <= last; bin += 1) {
      chroma[pitchClass[bin]] += magnitudes[bin];
    }
    let max = 0;
    for (let i = 0; i < 12; i += 1) max = Math.max(max, chroma[i]);
    if (max > 0) {
      for (let i = 0; i < 12; i += 1) chroma[i] /= max;
    }
  }

  private configureIfNeeded(sampleRate: number): void {
    if (this.sampleRate === sampleRate) return;
    this.sampleRate = sampleRate;
    this.frameInterval = HOP / sampleRate;
    this.bandPeakDecay = Math.exp(-this.frameInterval / 8);
    this.onsetScaleDecay = Math.exp(-this.frameInterval / 6);
    this.noveltyCoefficient = 1 - Math.exp(-this.frameInterval / 1.5);
    this.energyCoefficient = 1 - Math.exp(-this.frameInterval / 3.3);
    this.dropDecay = Math.exp(-this.frameInterval / .3);
    this.transientDecay = Math.exp(-this.frameInterval / .08);
    this.beatTracker.configure(this.frameInterval);
    this.bassBins = binsFor(sampleRate, 45, 160);
    this.midsBins = binsFor(sampleRate, 350, 2200);
    this.highsBins = binsFor(sampleRate, 3200, 12000);
    this.kickBins = binsFor(sampleRate, 40, 150);
    this.snareBins = binsFor(sampleRate, 200, 2000);
    this.hatBins = binsFor(sampleRate, 3000, 12000);
    this.fluxBands = logBands(sampleRate, 24);
    this.lastFluxBin = Math.max(this.kickBins.last, this.snareBins.last, this.hatBins.last,
      ...this.fluxBands.map(band => band.last));
    // Bin frequency rises with the index, so the 55 Hz–2 kHz chroma bins are one run.
    let first = 0, last = -1;
    for (let bin = 2; bin < WINDOW / 2; bin += 1) {
      const freq = (bin * sampleRate) / WINDOW;
      if (freq < 55 || freq > 2000) continue;
      if (last < 0) first = bin;
      last = bin;
      const midi = 69 + 12 * Math.log2(freq / 440);
      this.chromaPitchClass[bin] = ((Math.round(midi) % 12) + 12) % 12;
    }
    this.chromaBins = { first, last };
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
  const { first, last } = range;
  let sum = 0;
  for (let i = first; i <= last; i += 1) sum += Math.max(0, now[i] - prev[i]);
  return sum / Math.max(1, last - first + 1);
}

function updatedOnsetScale(scale: number, value: number, decay: number): number {
  return value > scale ? scale + (value - scale) * .3 : Math.max(MIN_ONSET_SCALE, scale * decay);
}

function clamp(value: number): number { return Math.max(0,Math.min(1,value)); }
