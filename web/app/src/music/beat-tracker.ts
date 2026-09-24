import type { BeatGrid, Metre, TimeFeel } from "./types";
import { MetreTracker } from "./metre";

export class BeatTracker {
  static readonly minimumTempo = 60;
  static readonly maximumTempo = 200;
  static beatsPerBar = 4;

  private static readonly historyDuration = 8;
  private static readonly estimationInterval = 0.25;
  private static readonly minimumHistoryDuration = 3.5;

  grid: BeatGrid = emptyGrid();

  private frameInterval: number;
  private capacity: number;
  private history: Float64Array;
  /** Kick-band onsets over the same window, scored separately from the full
   * spectrum so dense hi-hats cannot drag the search off the pulse. */
  private kickHistory: Float64Array;
  private writeIndex = 0;
  private frameCount = 0;
  private latestFrameTime = 0;
  private nextBeatTime = 0;
  private lastEstimateTime = Number.NEGATIVE_INFINITY;
  private smoothedConfidence = 0;
  private onsetScale = 0.001;
  private barEnergies: number[];
  private barOffset = 0;
  private pendingBarSlot = 0;
  private pendingBarEnergy = 0;
  private nextBarEnergy = 0;
  private scratch: Float64Array = new Float64Array(0);
  private kickScratch: Float64Array = new Float64Array(0);
  private autocorrelation: Float64Array = new Float64Array(0);
  private kickAutocorrelation: Float64Array = new Float64Array(0);
  private smoothedCorrelation: Float64Array = new Float64Array(0);
  private smoothedKickCorrelation: Float64Array = new Float64Array(0);
  private combScores: Float64Array = new Float64Array(0);
  /** A period that disagrees with the current one has to win the same argument
   * several estimates running before the grid moves. */
  private challengerInterval = 0;
  private challengerStreak = 0;
  private readonly metreTracker = new MetreTracker();
  private feelPreference: TimeFeel = "auto";
  private metreOverride: Metre | "auto" = "auto";

  constructor(frameInterval = 512 / 48_000) {
    this.frameInterval = Math.max(0.001, frameInterval);
    this.capacity = Math.max(64, Math.round(BeatTracker.historyDuration / this.frameInterval));
    this.history = new Float64Array(this.capacity);
    this.kickHistory = new Float64Array(this.capacity);
    this.barEnergies = new Array(BeatTracker.beatsPerBar).fill(0);
  }

  setPolicy(metre: Metre | "auto", feel: TimeFeel): void {
    this.metreOverride = metre;
    this.feelPreference = feel;
  }

  configure(frameInterval: number): void {
    const interval = Math.max(0.001, frameInterval);
    if (Math.abs(interval - this.frameInterval) <= this.frameInterval * 0.01) return;
    this.frameInterval = interval;
    this.capacity = Math.max(64, Math.round(BeatTracker.historyDuration / interval));
    this.history = new Float64Array(this.capacity);
    this.kickHistory = new Float64Array(this.capacity);
    this.reset();
  }

  reset(): void {
    this.grid = emptyGrid();
    this.writeIndex = 0;
    this.frameCount = 0;
    this.latestFrameTime = 0;
    this.nextBeatTime = 0;
    this.lastEstimateTime = Number.NEGATIVE_INFINITY;
    this.smoothedConfidence = 0;
    this.onsetScale = 0.001;
    this.barEnergies.fill(0);
    this.barOffset = 0;
    this.pendingBarSlot = 0;
    this.pendingBarEnergy = 0;
    this.nextBarEnergy = 0;
    this.history.fill(0);
    this.kickHistory.fill(0);
    this.challengerInterval = 0;
    this.challengerStreak = 0;
    this.metreTracker.reset();
  }

  process(onset: number, lowFrequencyOnset: number, time: number): number {
    const clampedOnset = Math.max(0, Math.min(1, onset));
    this.history[this.writeIndex] = clampedOnset;
    this.kickHistory[this.writeIndex] = Math.max(0, Math.min(1, lowFrequencyOnset));
    this.writeIndex = (this.writeIndex + 1) % this.capacity;
    this.frameCount += 1;
    this.latestFrameTime = time;
    this.onsetScale =
      clampedOnset > this.onsetScale
        ? this.onsetScale + (clampedOnset - this.onsetScale) * 0.3
        : Math.max(0.001, this.onsetScale * 0.9995);

    if (time - this.lastEstimateTime >= BeatTracker.estimationInterval) {
      this.lastEstimateTime = time;
      this.updateTempo(time);
    }

    if (this.grid.interval <= 0) return 0;
    this.correctPhase(clampedOnset, time);
    const emitted = this.emitBeats(time);
    this.accumulateBarEnergy(lowFrequencyOnset, time);
    if (emitted > 0) {
      this.applyMusicalTime();
    }
    return emitted;
  }

  private applyMusicalTime(): void {
    const detected = this.metreTracker.current();
    const metre = this.metreOverride === "auto" ? detected.metre : this.metreOverride;
    const feel =
      this.feelPreference === "auto" ? detected.feel : this.feelPreference;
    this.grid.metre = metre;
    this.grid.metreConfidence = detected.metreConfidence;
    this.grid.timeFeel = feel;
    const multiplier = feel === "half" ? 2 : feel === "double" ? 0.5 : 1;
    this.grid.feltInterval = this.grid.interval * multiplier;
    this.grid.feltTempo = this.grid.tempo / multiplier;
    this.grid.beatInBar = metre === 4 ? ((this.grid.beatCount - this.barOffset) % 4 + 4) % 4 : this.grid.beatCount % metre;
  }

  private emitBeats(time: number): number {
    if (this.nextBeatTime <= 0) this.nextBeatTime = time + this.grid.interval;
    if (time - this.nextBeatTime > this.grid.interval * 2) {
      this.grid.lastBeatTime = time;
      this.nextBeatTime = time + this.grid.interval;
      return 0;
    }

    let emitted = 0;
    while (this.nextBeatTime <= time + this.frameInterval * 0.5 && emitted < 2) {
      this.grid.lastBeatTime = this.nextBeatTime;
      this.grid.beatCount += 1;
      this.nextBeatTime += this.grid.interval;
      emitted += 1;
      this.rotateBarEnergy();
    }
    return emitted;
  }

  private accumulateBarEnergy(lowFrequencyOnset: number, time: number): void {
    if (this.grid.interval <= 0 || this.grid.lastBeatTime <= 0) return;
    const value = Math.max(0, lowFrequencyOnset);
    if (time - this.grid.lastBeatTime < this.grid.interval * 0.5) {
      this.pendingBarEnergy = Math.max(this.pendingBarEnergy, value);
    } else {
      this.nextBarEnergy = Math.max(this.nextBarEnergy, value);
    }
  }

  private rotateBarEnergy(): void {
    // Observe the completed nearest-beat window, not the FFT hop on which a
    // predicted grid event happened to be emitted.
    this.metreTracker.observe(this.grid.beatCount - 1, this.pendingBarEnergy, this.grid.tempo, this.grid.isLocked);
    const n = this.barEnergies.length;
    for (let i = 0; i < n; i += 1) this.barEnergies[i] *= 0.94;
    this.barEnergies[this.pendingBarSlot] += this.pendingBarEnergy;
    this.pendingBarSlot = ((this.grid.beatCount % n) + n) % n;
    this.pendingBarEnergy = this.nextBarEnergy;
    this.nextBarEnergy = 0;

    let strongest = 0;
    for (let i = 0; i < n; i += 1) {
      if (this.barEnergies[i] > this.barEnergies[strongest]) strongest = i;
    }
    this.barOffset = strongest;
    this.grid.beatInBar = ((this.pendingBarSlot - this.barOffset) % n + n) % n;
  }

  private correctPhase(onset: number, time: number): void {
    if (this.grid.interval <= 0 || this.grid.lastBeatTime <= 0) return;
    if (onset <= this.onsetScale * 0.45 || onset <= 0.1) return;
    const error = time - this.nearestBeatTime(time);
    if (Math.abs(error) >= this.grid.interval * 0.25) return;
    const strength = Math.min(1, onset / Math.max(0.001, this.onsetScale));
    const gain = 0.08 * strength;
    this.shiftGrid(error * gain);
    const adjusted = this.grid.interval + error * gain * 0.05;
    this.grid.interval = Math.min(
      60 / BeatTracker.minimumTempo,
      Math.max(60 / BeatTracker.maximumTempo, adjusted),
    );
    this.grid.tempo = 60 / this.grid.interval;
  }

  private nearestBeatTime(time: number): number {
    const beats = Math.round((time - this.grid.lastBeatTime) / this.grid.interval);
    return this.grid.lastBeatTime + beats * this.grid.interval;
  }

  private shiftGrid(delta: number): void {
    this.grid.lastBeatTime += delta;
    this.nextBeatTime += delta;
  }

  private resyncPhase(now: number): void {
    if (this.grid.interval <= 0) return;
    const anchor = this.estimatePhaseAnchor(this.grid.interval);
    if (anchor == null) {
      this.grid.lastBeatTime = now;
      this.nextBeatTime = now + this.grid.interval;
      return;
    }
    let last = anchor;
    const steps = Math.floor((now - last) / this.grid.interval);
    if (steps > 0) last += steps * this.grid.interval;
    this.grid.lastBeatTime = last;
    this.nextBeatTime = last + this.grid.interval;
  }

  private estimatePhaseAnchor(interval: number): number | null {
    const lagFrames = Math.max(2, Math.round(interval / this.frameInterval));
    const available = Math.min(this.frameCount, this.capacity);
    if (available <= lagFrames * 2) return null;

    let bestOffset = 0;
    let bestScore = -1;
    for (let offset = 0; offset < lagFrames; offset += 1) {
      let score = 0;
      let weight = 1;
      let framesAgo = offset;
      while (framesAgo < available && weight > 0.05) {
        score += this.historyValue(framesAgo) * weight;
        weight *= 0.85;
        framesAgo += lagFrames;
      }
      if (score > bestScore) {
        bestScore = score;
        bestOffset = offset;
      }
    }
    if (bestScore <= 0) return null;
    return this.latestFrameTime - bestOffset * this.frameInterval;
  }

  private updateTempo(now: number): void {
    const estimate = this.estimateTempo();
    if (!estimate) {
      this.smoothedConfidence *= 0.8;
      this.applyLockState();
      this.applyMusicalTime();
      return;
    }

    this.smoothedConfidence = this.smoothedConfidence * 0.7 + estimate.confidence * 0.3;
    if (this.grid.interval <= 0) {
      this.grid.interval = estimate.interval;
      this.resyncPhase(now);
    } else {
      const ratio = estimate.interval / this.grid.interval;
      if (Math.abs(ratio - 1) < 0.06) {
        this.grid.interval = this.grid.interval * 0.85 + estimate.interval * 0.15;
        this.challengerStreak = 0;
      } else {
        // Adopting a disagreeing period immediately let a tie between the beat
        // and a dotted or halved relative teleport the grid several times a
        // second, and every jump re-anchored the phase.
        const near =
          this.challengerInterval > 0 &&
          Math.abs(estimate.interval / this.challengerInterval - 1) < 0.06;
        this.challengerInterval = near
          ? this.challengerInterval * 0.6 + estimate.interval * 0.4
          : estimate.interval;
        this.challengerStreak = near ? this.challengerStreak + 1 : 1;
        const required = isSimpleRelative(estimate.interval, this.grid.interval) ? 4 : 2;
        if (this.challengerStreak >= required && estimate.confidence > 0.45) {
          this.grid.interval = this.challengerInterval;
          this.resyncPhase(now);
          this.challengerStreak = 0;
        }
      }
    }
    this.grid.tempo = 60 / this.grid.interval;

    const anchor = this.estimatePhaseAnchor(this.grid.interval);
    if (anchor != null) {
      const error = anchor - this.nearestBeatTime(anchor);
      this.shiftGrid(error * (Math.abs(error) > this.grid.interval * 0.12 ? 0.5 : 0.15));
    }
    this.applyLockState();
    this.applyMusicalTime();
  }

  private applyLockState(): void {
    this.smoothedConfidence = Math.max(0, Math.min(1, this.smoothedConfidence));
    this.grid.isLocked = this.smoothedConfidence >= (this.grid.isLocked ? 0.22 : 0.38);
    this.grid.confidence = this.smoothedConfidence;
  }

  private estimateTempo(): { interval: number; confidence: number } | null {
    const available = Math.min(this.frameCount, this.capacity);
    if (available * this.frameInterval < BeatTracker.minimumHistoryDuration) return null;

    if (this.scratch.length !== available) {
      this.scratch = new Float64Array(available);
      this.kickScratch = new Float64Array(available);
    }
    const variance = centre(this.scratch, available, (n) => this.historyValue(n));
    if (variance <= 1e-9) return null;
    const kickVariance = centre(this.kickScratch, available, (n) => this.kickHistoryValue(n));

    // How peaky the onset function is over the window. Drums give a tall crest
    // against a low floor; a held chord's analysis ripple does not. Only the
    // first means there is a pulse to find.
    let peak = 0;
    let levelTotal = 0;
    for (let i = 0; i < available; i += 1) {
      const value = this.historyValue(i);
      if (value > peak) peak = value;
      levelTotal += value;
    }
    const meanLevel = levelTotal / available;
    const peakiness = meanLevel > 1e-6 ? peak / meanLevel : 0;

    const minimumLag = Math.max(2, Math.floor(60 / BeatTracker.maximumTempo / this.frameInterval));
    const maximumLag = Math.min(
      Math.floor(available / 3) - 1,
      Math.floor(60 / BeatTracker.minimumTempo / this.frameInterval),
    );
    if (minimumLag + 2 >= maximumLag) return null;
    const combLimit = maximumLag * 3;
    if (combLimit >= available) return null;

    if (this.autocorrelation.length !== combLimit + 1) {
      this.autocorrelation = new Float64Array(combLimit + 1);
      this.kickAutocorrelation = new Float64Array(combLimit + 1);
      this.smoothedCorrelation = new Float64Array(combLimit + 1);
      this.smoothedKickCorrelation = new Float64Array(combLimit + 1);
    }
    correlate(this.autocorrelation, this.scratch, available, variance, combLimit);
    smooth(this.smoothedCorrelation, this.autocorrelation, combLimit);
    const hasKick = kickVariance > 1e-9;
    if (hasKick) {
      correlate(this.kickAutocorrelation, this.kickScratch, available, kickVariance, combLimit);
      smooth(this.smoothedKickCorrelation, this.kickAutocorrelation, combLimit);
    }

    if (this.combScores.length !== maximumLag + 1) {
      this.combScores = new Float64Array(maximumLag + 1);
    }
    let bestLag = minimumLag;
    let bestScore = Number.NEGATIVE_INFINITY;
    for (let lag = minimumLag; lag <= maximumLag; lag += 1) {
      const broad = comb(this.smoothedCorrelation, lag);
      // The kick band votes separately; material with no kick at all falls
      // back to the broadband term.
      const kick = hasKick ? comb(this.smoothedKickCorrelation, lag) : broad;
      const bpm = 60 / (lag * this.frameInterval);
      const score = Math.max(0, 0.55 * broad + 0.45 * kick) * tempoPrior(bpm);
      this.combScores[lag] = score;
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }
    if (bestScore <= 0) return null;

    const refinedLag =
      bestLag +
      parabolicOffset(
        bestLag > minimumLag ? this.combScores[bestLag - 1] : 0,
        this.combScores[bestLag],
        bestLag < maximumLag ? this.combScores[bestLag + 1] : 0,
      );
    const interval = Math.min(
      60 / BeatTracker.minimumTempo,
      Math.max(60 / BeatTracker.maximumTempo, refinedLag * this.frameInterval),
    );

    // The best score among genuinely different periods, skipping the winner's
    // own peak. Measured against the mean of every lag instead, confidence
    // reports near 1 even when a rival period is neck and neck.
    let rivalScore = 0;
    for (let lag = minimumLag; lag <= maximumLag; lag += 1) {
      if (Math.abs(Math.log2(lag / bestLag)) < 0.14) continue;
      if (this.combScores[lag] > rivalScore) rivalScore = this.combScores[lag];
    }
    const separation = Math.max(0, (bestScore - rivalScore) / bestScore);

    const coefficient = Math.max(0, this.smoothedCorrelation[bestLag]);
    const activity = Math.min(1, Math.sqrt(variance) * 6);
    const rhythmic = Math.min(1, Math.max(0, (peakiness - 2.2) / 3.5));
    // A pulse has to be strong, clearly ahead of its rivals, loud enough to
    // measure, and actually percussive.
    const confidence =
      Math.min(1, coefficient * 1.8) *
      Math.min(1, separation * 2.4) *
      activity *
      (0.25 + 0.75 * rhythmic);
    return { interval, confidence: Math.max(0, Math.min(1, confidence)) };
  }

  private kickHistoryValue(framesAgo: number): number {
    const available = Math.min(this.frameCount, this.capacity);
    if (framesAgo < 0 || framesAgo >= available) return 0;
    let index = this.writeIndex - 1 - framesAgo;
    while (index < 0) index += this.capacity;
    return this.kickHistory[index % this.capacity];
  }

  private historyValue(framesAgo: number): number {
    const available = Math.min(this.frameCount, this.capacity);
    if (framesAgo < 0 || framesAgo >= available) return 0;
    let index = this.writeIndex - 1 - framesAgo;
    while (index < 0) index += this.capacity;
    return this.history[index % this.capacity];
  }
}

function emptyGrid(): BeatGrid {
  return {
    tempo: 0,
    interval: 0,
    confidence: 0,
    lastBeatTime: 0,
    beatInBar: 0,
    beatCount: 0,
    isLocked: false,
    metre: 4,
    metreConfidence: 0,
    timeFeel: "straight",
    feltInterval: 0,
    feltTempo: 0,
  };
}

function tempoPrior(bpm: number): number {
  const octaves = Math.log2(bpm / 120) / 0.9;
  return Math.exp(-0.5 * octaves * octaves);
}

function parabolicOffset(previous: number, peak: number, next: number): number {
  const denominator = previous - 2 * peak + next;
  if (Math.abs(denominator) <= 1e-12) return 0;
  const offset = (0.5 * (previous - next)) / denominator;
  return Math.max(-0.5, Math.min(0.5, offset));
}

/** Mean-removes the newest `available` frames into `buffer`; returns variance. */
function centre(buffer: Float64Array, available: number, read: (framesAgo: number) => number): number {
  let total = 0;
  for (let i = 0; i < available; i += 1) {
    const value = read(available - 1 - i);
    buffer[i] = value;
    total += value;
  }
  const mean = total / available;
  let variance = 0;
  for (let i = 0; i < available; i += 1) {
    buffer[i] -= mean;
    variance += buffer[i] * buffer[i];
  }
  return variance / available;
}

function correlate(
  into: Float64Array,
  source: Float64Array,
  available: number,
  variance: number,
  limit: number,
): void {
  for (let lag = 1; lag <= limit; lag += 1) {
    let sum = 0;
    for (let index = lag; index < available; index += 1) sum += source[index] * source[index - lag];
    into[lag] = sum / ((available - lag) * variance);
  }
}

/**
 * Three-tap smoothing. A beat period rarely lands on a whole number of analysis
 * hops, so its correlation peak is split across two lags; a rival period that
 * happens to land on one would otherwise win on bin alignment rather than on
 * the music.
 */
function smooth(into: Float64Array, source: Float64Array, limit: number): void {
  for (let lag = 1; lag <= limit; lag += 1) {
    const previous = lag > 1 ? source[lag - 1] : source[lag];
    const next = lag < limit ? source[lag + 1] : source[lag];
    into[lag] = 0.25 * previous + 0.5 * source[lag] + 0.25 * next;
  }
}

function comb(table: Float64Array, lag: number): number {
  return (table[lag] + 0.5 * table[lag * 2] + 0.25 * table[lag * 3]) / 1.75;
}

/**
 * True when `candidate` is within a few percent of a simple musical relative of
 * `current` — half, double, three halves, and so on. Those are the likeliest
 * ways to be wrong, so they have to argue longer before the grid moves.
 */
function isSimpleRelative(candidate: number, current: number): boolean {
  if (!(current > 0) || !(candidate > 0)) return false;
  const ratio = candidate / current;
  return [0.5, 2, 1.5, 2 / 3, 3, 1 / 3, 4 / 3, 0.75].some((r) => Math.abs(ratio / r - 1) < 0.05);
}
