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
  private autocorrelation: Float64Array = new Float64Array(0);
  private combScores: Float64Array = new Float64Array(0);
  private readonly metreTracker = new MetreTracker();
  private feelPreference: TimeFeel = "auto";
  private metreOverride: Metre | "auto" = "auto";

  constructor(frameInterval = 512 / 48_000) {
    this.frameInterval = Math.max(0.001, frameInterval);
    this.capacity = Math.max(64, Math.round(BeatTracker.historyDuration / this.frameInterval));
    this.history = new Float64Array(this.capacity);
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
    this.metreTracker.reset();
  }

  process(onset: number, lowFrequencyOnset: number, time: number): number {
    const clampedOnset = Math.max(0, Math.min(1, onset));
    this.history[this.writeIndex] = clampedOnset;
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
      this.metreTracker.observe(
        this.grid.beatCount,
        Math.max(0, lowFrequencyOnset),
        this.grid.tempo,
        this.grid.isLocked,
      );
      this.applyMusicalTime();
    }
    return emitted;
  }

  private applyMusicalTime(): void {
    const detected = this.metreTracker.current();
    const metre = this.metreOverride === "auto" ? detected.metre : this.metreOverride;
    const feel =
      this.feelPreference === "auto" ? detected.feel : this.feelPreference;
    if (metre !== BeatTracker.beatsPerBar) {
      BeatTracker.beatsPerBar = metre;
      this.barEnergies = new Array(metre).fill(0);
    }
    this.grid.metre = metre;
    this.grid.metreConfidence = detected.metreConfidence;
    this.grid.timeFeel = feel;
    const multiplier = feel === "half" ? 2 : feel === "double" ? 0.5 : 1;
    this.grid.feltInterval = this.grid.interval * multiplier;
    this.grid.feltTempo = this.grid.tempo / multiplier;
    this.grid.beatInBar = ((this.grid.beatCount - this.barOffset) % metre + metre) % metre;
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
      } else if (estimate.confidence > 0.45) {
        this.grid.interval = estimate.interval;
        this.resyncPhase(now);
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

    if (this.scratch.length !== available) this.scratch = new Float64Array(available);
    let total = 0;
    for (let i = 0; i < available; i += 1) {
      const value = this.historyValue(available - 1 - i);
      this.scratch[i] = value;
      total += value;
    }
    const mean = total / available;
    let variance = 0;
    for (let i = 0; i < available; i += 1) {
      this.scratch[i] -= mean;
      variance += this.scratch[i] * this.scratch[i];
    }
    variance /= available;
    if (variance <= 1e-9) return null;

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
    }
    for (let lag = 1; lag <= combLimit; lag += 1) {
      let sum = 0;
      for (let index = lag; index < available; index += 1) {
        sum += this.scratch[index] * this.scratch[index - lag];
      }
      this.autocorrelation[lag] = sum / ((available - lag) * variance);
    }

    if (this.combScores.length !== maximumLag + 1) {
      this.combScores = new Float64Array(maximumLag + 1);
    }
    let bestLag = minimumLag;
    let bestScore = Number.NEGATIVE_INFINITY;
    let scoreTotal = 0;
    for (let lag = minimumLag; lag <= maximumLag; lag += 1) {
      const comb =
        (this.autocorrelation[lag] +
          0.5 * this.autocorrelation[lag * 2] +
          0.25 * this.autocorrelation[lag * 3]) /
        1.75;
      const bpm = 60 / (lag * this.frameInterval);
      const score = Math.max(0, comb) * tempoPrior(bpm);
      this.combScores[lag] = score;
      scoreTotal += score;
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

    const meanScore = scoreTotal / (maximumLag - minimumLag + 1);
    const prominence = (bestScore - meanScore) / bestScore;
    const coefficient = Math.max(0, this.autocorrelation[bestLag]);
    const activity = Math.min(1, Math.sqrt(variance) * 6);
    const confidence = Math.min(1, coefficient * 1.8) * Math.min(1, prominence * 2.2) * activity;
    return { interval, confidence: Math.max(0, Math.min(1, confidence)) };
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
