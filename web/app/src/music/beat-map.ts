import { MusicFeatureAnalyzer } from "./analyzer";
import { clamp01, type AudioReactiveSnapshot, type HopFeature } from "./types";

/**
 * A beat map is a whole song analysed ahead of time: every beat, where each
 * bar starts, how loud each bar is, and the onset envelope that lets a live
 * capture find its place in the song again.
 *
 * Live analysis only ever hears the past, so it has to infer the grid and
 * can't know the next bar's energy until it has heard it. With a map the show
 * knows what is coming and plays it against a clock instead.
 *
 * Kept in lockstep with `LumenDesk/Services/BeatMap.swift`. The algorithms,
 * constants and test vectors are the same on both sides.
 */
export const BEAT_MAP_VERSION = 2;
/** Samples per second of every envelope a map stores or is built from. */
export const ENVELOPE_RATE = 100;
/** Bars in a map always hold four beats; metre overrides still apply on top. */
export const MAP_BEATS_PER_BAR = 4;

const MIN_BPM = 55;
const MAX_BPM = 220;
const PRIOR_BPM = 120;
const PRIOR_OCTAVE_WIDTH = 0.9;
/** How strongly the dynamic program holds beats to the estimated period. */
const TIGHTNESS = 100;
const MINIMUM_DURATION = 8;

export interface BeatMap {
  version: number;
  /** Seconds of audio the map covers, measured from the start of the track. */
  duration: number;
  /** Dominant tempo in BPM. Local intervals come from `beats`. */
  tempo: number;
  /** Beat times in seconds from the start of the track, ascending. */
  beats: number[];
  /** Index in `beats` of the first downbeat, 0…3. Earlier beats are a pickup. */
  downbeatOffset: number;
  /** 0…1 energy per bar. Bar k starts at `beats[downbeatOffset + 4k]`. */
  barEnergy: number[];
  /** Onset strength at `ENVELOPE_RATE`, sample i at i / ENVELOPE_RATE seconds. */
  envelope: number[];
  /** 0…1: how periodic the onset envelope is at the chosen tempo. */
  confidence: number;
}

/** Where a track position falls on a map. */
export interface BeatMapGrid {
  beatIndex: number;
  beatTime: number;
  interval: number;
  /** Beat index shifted so every downbeat is a multiple of four. */
  gridBeatPosition: number;
  beatInBar: number;
  barIndex: number;
  barEnergy: number;
}

export interface AlignmentResult {
  /** Seconds to add to the expected position. */
  offset: number;
  correlation: number;
  /** How far the best lag beats the best lag at least 60 ms away. */
  margin: number;
}

// MARK: - Building

/**
 * Resamples hop features onto the fixed envelope rate by linear
 * interpolation. Hop times are track positions in seconds.
 */
export function resampleHops(hops: readonly HopFeature[], rate = ENVELOPE_RATE): {
  onset: Float64Array; kick: Float64Array; energy: Float64Array; duration: number;
} {
  const sorted = isSorted(hops) ? hops : [...hops].sort((a, b) => a.time - b.time);
  const duration = sorted.length ? Math.max(0, sorted[sorted.length - 1].time) : 0;
  const count = Math.max(0, Math.floor(duration * rate) + 1);
  const onset = new Float64Array(count), kick = new Float64Array(count), energy = new Float64Array(count);
  if (sorted.length === 0) return { onset, kick, energy, duration };
  let j = 0;
  for (let i = 0; i < count; i += 1) {
    const t = i / rate;
    while (j + 1 < sorted.length && sorted[j + 1].time <= t) j += 1;
    const a = sorted[j], b = sorted[Math.min(j + 1, sorted.length - 1)];
    if (t <= a.time || b === a || b.time <= a.time) {
      onset[i] = a.onset; kick[i] = a.kick; energy[i] = a.energy;
    } else {
      const f = (t - a.time) / (b.time - a.time);
      onset[i] = a.onset + (b.onset - a.onset) * f;
      kick[i] = a.kick + (b.kick - a.kick) * f;
      energy[i] = a.energy + (b.energy - a.energy) * f;
    }
  }
  return { onset, kick, energy, duration };
}

/**
 * Onset novelty: the envelope minus its half-second moving average, rectified.
 * Removing the slow part keeps loud passages from correlating with everything.
 */
export function onsetNovelty(envelope: ArrayLike<number>, rate = ENVELOPE_RATE): Float64Array {
  const n = envelope.length;
  const out = new Float64Array(n);
  const half = Math.max(1, Math.round(rate * 0.25));
  const prefix = new Float64Array(n + 1);
  for (let i = 0; i < n; i += 1) prefix[i + 1] = prefix[i] + envelope[i];
  for (let i = 0; i < n; i += 1) {
    const lo = Math.max(0, i - half), hi = Math.min(n, i + half + 1);
    const mean = (prefix[hi] - prefix[lo]) / (hi - lo);
    out[i] = Math.max(0, envelope[i] - mean);
  }
  return out;
}

/**
 * Global tempo from the autocorrelation of the novelty, weighted by a
 * log-normal prior around 120 BPM. Each lag also scores half of its double,
 * which favours the beat over the bar while the prior keeps eighth notes out.
 * Returns the period in envelope samples (fractional) and a 0…1 confidence.
 */
export function estimatePeriod(novelty: ArrayLike<number>, rate = ENVELOPE_RATE): { period: number; confidence: number } {
  const n = novelty.length;
  const minLag = Math.max(2, Math.floor((60 / MAX_BPM) * rate));
  const maxLag = Math.ceil((60 / MIN_BPM) * rate);
  if (n < maxLag * 4) return { period: 0, confidence: 0 };
  let mean = 0;
  for (let i = 0; i < n; i += 1) mean += novelty[i];
  mean /= n;
  const centred = new Float64Array(n);
  let zeroLag = 0;
  for (let i = 0; i < n; i += 1) { centred[i] = novelty[i] - mean; zeroLag += centred[i] * centred[i]; }
  if (zeroLag <= 1e-12) return { period: 0, confidence: 0 };
  const correlation = new Float64Array(maxLag * 2 + 2);
  for (let lag = minLag; lag < correlation.length && lag < n; lag += 1) {
    let sum = 0;
    for (let i = 0; i + lag < n; i += 1) sum += centred[i] * centred[i + lag];
    correlation[lag] = (sum / (n - lag)) / (zeroLag / n);
  }
  const priorLag = (60 / PRIOR_BPM) * rate;
  let bestLag = 0, bestScore = -Infinity;
  const scores = new Float64Array(maxLag + 2);
  for (let lag = minLag; lag <= maxLag; lag += 1) {
    const octaves = Math.log2(lag / priorLag) / PRIOR_OCTAVE_WIDTH;
    const weight = Math.exp(-0.5 * octaves * octaves);
    const score = weight * (correlation[lag] + 0.5 * (correlation[lag * 2] ?? 0));
    scores[lag] = score;
    if (score > bestScore) { bestScore = score; bestLag = lag; }
  }
  if (bestLag === 0 || !(bestScore > 0)) return { period: 0, confidence: 0 };
  // Parabolic refinement between neighbouring lags.
  let period = bestLag;
  if (bestLag > minLag && bestLag < maxLag) {
    const a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1];
    const denominator = a - 2 * b + c;
    if (denominator < 0) period = bestLag + Math.max(-0.5, Math.min(0.5, 0.5 * (a - c) / denominator));
  }
  return { period, confidence: clamp01(correlation[bestLag]) };
}

/**
 * Dynamic-programming beat tracking (Ellis 2007): each frame's score is its
 * novelty plus the best predecessor score, penalised by how far the gap is
 * from the period in log terms. Returns beat frames in ascending order.
 */
export function trackBeats(novelty: ArrayLike<number>, period: number): number[] {
  const n = novelty.length;
  if (!(period > 1) || n < period * 2) return [];
  let mean = 0, square = 0;
  for (let i = 0; i < n; i += 1) { mean += novelty[i]; square += novelty[i] * novelty[i]; }
  mean /= n;
  const deviation = Math.sqrt(Math.max(0, square / n - mean * mean));
  if (deviation <= 1e-12) return [];
  const local = new Float64Array(n);
  for (let i = 0; i < n; i += 1) local[i] = novelty[i] / deviation;
  const score = new Float64Array(n);
  const back = new Int32Array(n).fill(-1);
  const nearest = Math.max(1, Math.round(period / 2));
  const farthest = Math.max(nearest + 1, Math.round(period * 2));
  // The penalty depends only on the gap, so compute it once per gap rather
  // than once per frame pair: an hour of audio is millions of pairs.
  const penalty = new Float64Array(farthest + 1);
  for (let gap = nearest; gap <= farthest; gap += 1) {
    const ratio = Math.log(gap / period);
    penalty[gap] = TIGHTNESS * ratio * ratio;
  }
  for (let t = 0; t < n; t += 1) {
    let best = -Infinity, from = -1;
    const first = Math.max(0, t - farthest), last = t - nearest;
    for (let p = first; p <= last; p += 1) {
      const candidate = score[p] - penalty[t - p];
      if (candidate > best) { best = candidate; from = p; }
    }
    if (from >= 0 && best > 0) { score[t] = local[t] + best; back[t] = from; }
    else score[t] = local[t];
  }
  // The chain ends at the best score inside the final period.
  let end = n - 1;
  for (let t = Math.max(0, n - Math.round(period)); t < n; t += 1) if (score[t] > score[end]) end = t;
  const beats: number[] = [];
  for (let t = end; t >= 0; t = back[t]) {
    beats.push(t);
    if (back[t] < 0) break;
  }
  beats.reverse();
  return trimSilentEnds(beats, local, period);
}

/** Drops beats at either end whose surroundings hold almost no onset energy. */
function trimSilentEnds(beats: number[], local: Float64Array, period: number): number[] {
  if (beats.length < 3) return beats;
  const reach = Math.max(1, Math.round(period / 2));
  const strength = beats.map(frame => {
    let sum = 0, count = 0;
    for (let i = Math.max(0, frame - reach); i <= Math.min(local.length - 1, frame + reach); i += 1) { sum += local[i]; count += 1; }
    return count ? sum / count : 0;
  });
  const sorted = [...strength].sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];
  const floor = median * 0.15;
  let first = 0, last = beats.length - 1;
  while (first < last && strength[first] < floor) first += 1;
  while (last > first && strength[last] < floor) last -= 1;
  return beats.slice(first, last + 1);
}

/**
 * Which of the four beat phases is the downbeat: the one where the low band
 * hits hardest, with a little help from broadband onsets.
 */
export function pickDownbeatOffset(beatFrames: readonly number[], kick: ArrayLike<number>, onset: ArrayLike<number>): number {
  if (beatFrames.length < MAP_BEATS_PER_BAR * 2) return 0;
  const sums = new Float64Array(MAP_BEATS_PER_BAR), counts = new Float64Array(MAP_BEATS_PER_BAR);
  for (let index = 0; index < beatFrames.length; index += 1) {
    const frame = beatFrames[index];
    let peakKick = 0, peakOnset = 0;
    for (let i = Math.max(0, frame - 3); i <= Math.min(kick.length - 1, frame + 3); i += 1) {
      peakKick = Math.max(peakKick, kick[i]);
      peakOnset = Math.max(peakOnset, onset[i] ?? 0);
    }
    const phase = index % MAP_BEATS_PER_BAR;
    sums[phase] += peakKick + 0.25 * peakOnset;
    counts[phase] += 1;
  }
  let best = 0;
  for (let phase = 1; phase < MAP_BEATS_PER_BAR; phase += 1) {
    if (sums[phase] / Math.max(1, counts[phase]) > sums[best] / Math.max(1, counts[best]) + 1e-9) best = phase;
  }
  return best;
}

/**
 * 0…1 energy per bar: 60 % absolute loudness (a mean energy of 0.75 is full),
 * 40 % rank within the song. The absolute part keeps a quiet song's loudest
 * bar from reading as a club drop; the rank part still lets a song move.
 */
export function barEnergies(beats: readonly number[], downbeatOffset: number, energy: ArrayLike<number>, rate = ENVELOPE_RATE): number[] {
  const means: number[] = [];
  for (let start = downbeatOffset; start < beats.length; start += MAP_BEATS_PER_BAR) {
    const from = beats[start];
    const interval = start + 1 < beats.length ? beats[start + 1] - beats[start] : 0.5;
    const to = start + MAP_BEATS_PER_BAR < beats.length ? beats[start + MAP_BEATS_PER_BAR] : from + interval * MAP_BEATS_PER_BAR;
    const a = Math.max(0, Math.floor(from * rate)), b = Math.min(energy.length, Math.ceil(to * rate));
    let sum = 0;
    for (let i = a; i < b; i += 1) sum += energy[i];
    means.push(b > a ? sum / (b - a) : 0);
  }
  if (means.length === 0) return [];
  const order = means.map((value, index) => ({ value, index })).sort((x, y) => x.value - y.value || x.index - y.index);
  const rank = new Float64Array(means.length);
  // Equal loudness has equal rank. Breaking ties by time used to invent a
  // build-up through a steady passage; a single bar gets the neutral rank.
  for (let first = 0; first < order.length;) {
    let end = first + 1;
    while (end < order.length && order[end].value - order[first].value < 1e-9) end++;
    const percentile = means.length === 1 ? 0.5 : (first + end - 1) / (2 * (means.length - 1));
    for (let i = first; i < end; i++) rank[order[i].index] = percentile;
    first = end;
  }
  return means.map((mean, index) => clamp01(0.6 * clamp01(mean / 0.75) + 0.4 * rank[index]));
}

/**
 * Builds a map from hop features whose times are track positions. Returns
 * null for audio too short or too irregular to hold a grid.
 */
export function buildBeatMap(hops: readonly HopFeature[], rate = ENVELOPE_RATE): BeatMap | null {
  const steps = beatMapSteps(hops, rate);
  for (;;) {
    const step = steps.next();
    if (step.done) return step.value;
  }
}

/**
 * The same build, handing the event loop back between its phases and stopping
 * as soon as `shouldContinue` says so. Each phase is linear in the track's
 * length, so an hour-long mix never holds the page for the whole build.
 */
export async function buildBeatMapAsync(
  hops: readonly HopFeature[],
  shouldContinue: () => boolean = () => true,
  rate = ENVELOPE_RATE,
): Promise<BeatMap | null> {
  const steps = beatMapSteps(hops, rate);
  for (;;) {
    if (!shouldContinue()) return null;
    const step = steps.next();
    if (step.done) return step.value;
    await new Promise(resolve => setTimeout(resolve, 0));
  }
}

function* beatMapSteps(hops: readonly HopFeature[], rate: number): Generator<void, BeatMap | null, void> {
  const { onset, kick, energy, duration } = resampleHops(hops, rate);
  if (duration < MINIMUM_DURATION) return null;
  yield;
  const novelty = onsetNovelty(onset, rate);
  const { period, confidence } = estimatePeriod(novelty, rate);
  if (!(period > 0)) return null;
  yield;
  const frames = trackBeats(novelty, period);
  if (frames.length < MAP_BEATS_PER_BAR * 2) return null;
  yield;
  const downbeatOffset = pickDownbeatOffset(frames, kick, onset);
  const beats = frames.map(frame => frame / rate);
  return {
    version: BEAT_MAP_VERSION,
    duration,
    tempo: (60 * rate) / period,
    beats,
    downbeatOffset,
    barEnergy: barEnergies(beats, downbeatOffset, energy, rate),
    envelope: Array.from(onset, value => Math.round(value * 1000) / 1000),
    confidence,
  };
}

export interface AudioBufferLike {
  readonly numberOfChannels: number;
  readonly sampleRate: number;
  readonly length: number;
  getChannelData(channel: number): Float32Array;
}

/**
 * Runs the live analyzer over a whole decoded file, faster than real time,
 * and builds its map. Yields to the event loop between chunks so the page
 * stays responsive; `shouldContinue` lets a stopped show cancel it.
 */
export async function analyzeAudioBuffer(
  buffer: AudioBufferLike,
  onProgress?: (fraction: number) => void,
  shouldContinue: () => boolean = () => true,
): Promise<BeatMap | null> {
  const hops: HopFeature[] = [];
  const analyzer = new MusicFeatureAnalyzer("Beat map");
  analyzer.onHop = hop => hops.push({ ...hop });
  const left = buffer.getChannelData(0);
  const right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : null;
  const chunk = 4096;
  for (let start = 0, step = 0; start < buffer.length; start += chunk, step += 1) {
    if (!shouldContinue()) return null;
    const end = Math.min(buffer.length, start + chunk);
    const l = left.subarray(start, end);
    analyzer.analyze(l, end / buffer.sampleRate, right ? { left: l, right: right.subarray(start, end) } : undefined, buffer.sampleRate);
    if (step % 24 === 23) {
      onProgress?.(end / buffer.length);
      await new Promise(resolve => setTimeout(resolve, 0));
    }
  }
  onProgress?.(1);
  return buildBeatMapAsync(hops, shouldContinue);
}

// MARK: - Playing a map

/** Where `position` falls on the map, or null before the first beat or after the last. */
export function beatMapGridAt(map: BeatMap, position: number): BeatMapGrid | null {
  const beats = map.beats;
  if (beats.length < 2 || !Number.isFinite(position)) return null;
  if (position < beats[0] - 0.05) return null;
  let lo = 0, hi = beats.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (beats[mid] <= position) lo = mid; else hi = mid - 1;
  }
  const index = lo;
  const lastIndex = beats.length - 1;
  const interval = index < lastIndex ? beats[index + 1] - beats[index] : beats[lastIndex] - beats[lastIndex - 1];
  if (!(interval > 0)) return null;
  if (index === lastIndex && position - beats[lastIndex] > interval * 1.5) return null;
  const shift = (MAP_BEATS_PER_BAR - (map.downbeatOffset % MAP_BEATS_PER_BAR)) % MAP_BEATS_PER_BAR;
  const gridBeatPosition = index + shift;
  const barIndex = Math.floor((index - map.downbeatOffset) / MAP_BEATS_PER_BAR);
  const bars = map.barEnergy;
  const barEnergy = bars.length ? bars[Math.max(0, Math.min(bars.length - 1, barIndex))] : 0.5;
  return {
    beatIndex: index,
    beatTime: beats[index],
    interval,
    gridBeatPosition,
    beatInBar: gridBeatPosition % MAP_BEATS_PER_BAR,
    barIndex,
    barEnergy,
  };
}

/**
 * Replaces the snapshot's inferred grid with the map's. `position` is the
 * track position at `timestamp`, both on the renderer's clock. Loudness and
 * transients stay live, so the bed still follows what is actually playing.
 */
export function applyBeatMap(
  snapshot: AudioReactiveSnapshot,
  map: BeatMap,
  position: number,
  timestamp: number,
): AudioReactiveSnapshot {
  const grid = beatMapGridAt(map, position);
  if (!grid || map.confidence < 0.08) return { ...snapshot, barEnergy: undefined, beatMapActive: false };
  return {
    ...snapshot,
    beatReferenceTime: timestamp - (position - grid.beatTime),
    beatInterval: grid.interval,
    tempo: 60 / grid.interval,
    beatConfidence: clamp01(0.55 + map.confidence * 1.5),
    isTempoLocked: true,
    gridBeatPosition: grid.gridBeatPosition,
    beatCount: grid.gridBeatPosition,
    beatInBar: grid.beatInBar,
    metre: MAP_BEATS_PER_BAR,
    metreConfidence: 1,
    timeFeel: "straight",
    feltInterval: grid.interval,
    feltTempo: 60 / grid.interval,
    barEnergy: grid.barEnergy,
    beatMapActive: true,
  };
}

// MARK: - Finding the place again

/**
 * Normalised cross-correlation of a live onset envelope against the map
 * around where the clock says the song is. `live` is sampled at the map rate
 * and its last sample sits at `endPosition`. Small offsets are preferred, so a
 * neighbouring beat that correlates just as well cannot pull the clock away.
 */
export function alignToBeatMap(
  live: ArrayLike<number>,
  map: BeatMap,
  endPosition: number,
  radius = 0.4,
  rate = ENVELOPE_RATE,
): AlignmentResult | null {
  const n = live.length;
  if (n < rate * 2) return null;
  const liveNormal = zScore(live);
  if (!liveNormal) return null;
  const startIndex = Math.round((endPosition - (n - 1) / rate) * rate);
  const steps = Math.max(1, Math.round(radius * rate));
  const scores: { lag: number; score: number; correlation: number }[] = [];
  const segment = new Float64Array(n);
  for (let lag = -steps; lag <= steps; lag += 1) {
    const first = startIndex + lag;
    if (first < 0 || first + n > map.envelope.length) continue;
    for (let i = 0; i < n; i += 1) segment[i] = map.envelope[first + i];
    const normal = zScore(segment);
    if (!normal) continue;
    let sum = 0;
    for (let i = 0; i < n; i += 1) sum += liveNormal[i] * normal[i];
    const correlation = sum / n;
    scores.push({ lag, correlation, score: correlation - 0.15 * Math.abs(lag) / rate });
  }
  if (scores.length === 0) return null;
  let best = scores[0];
  for (const entry of scores) if (entry.score > best.score) best = entry;
  const apart = Math.round(0.06 * rate);
  let rival = -Infinity;
  for (const entry of scores) if (Math.abs(entry.lag - best.lag) >= apart) rival = Math.max(rival, entry.score);
  return {
    offset: best.lag / rate,
    correlation: best.correlation,
    margin: Number.isFinite(rival) ? best.score - rival : best.score,
  };
}

/** A correction worth applying: clear peak, clear winner. */
export function isTrustworthyAlignment(result: AlignmentResult | null): result is AlignmentResult {
  return result != null && result.correlation >= 0.3 && result.margin >= 0.04;
}

/**
 * Dead-reckons a player's position between reports. Reports that land close
 * to the prediction only nudge the anchor, because poll timing jitters; a
 * report far from it is a seek, a skip or a stall and re-anchors outright.
 * `correction` carries what the aligner learned on top of the reports.
 */
export class PlaybackClock {
  private anchorPosition = 0;
  private anchorTime = 0;
  private playing = false;
  private known = false;
  correction = 0;

  get isKnown(): boolean { return this.known; }
  get isPlaying(): boolean { return this.playing; }

  /** Returns "jumped" when the report could not be reconciled with the prediction. */
  report(position: number, at: number, playing: boolean, tolerance = 0.25): "started" | "jumped" | "held" {
    if (!this.known) {
      this.anchor(position, at, playing);
      this.correction = 0;
      return "started";
    }
    const predicted = this.anchorPosition + (this.playing ? at - this.anchorTime : 0);
    if (playing !== this.playing || Math.abs(position - predicted) > tolerance) {
      const jumped = Math.abs(position - predicted) > tolerance;
      this.anchor(position, at, playing);
      if (jumped) { this.correction = 0; return "jumped"; }
      return "held";
    }
    // Within tolerance: drift a tenth of the way toward the report.
    this.anchor(predicted + (position - predicted) * 0.1, at, playing);
    return "held";
  }

  positionAt(time: number): number {
    return this.anchorPosition + (this.playing ? time - this.anchorTime : 0) + this.correction;
  }

  /** Applies part of an aligner offset. Tiny offsets are noise, large ones a wrong match. */
  nudge(offset: number): boolean {
    if (Math.abs(offset) < 0.015 || Math.abs(offset) > 0.35) return false;
    this.correction += offset * 0.6;
    return true;
  }

  reset(): void {
    this.known = false;
    this.playing = false;
    this.correction = 0;
  }

  private anchor(position: number, at: number, playing: boolean): void {
    this.anchorPosition = position;
    this.anchorTime = at;
    this.playing = playing;
    this.known = true;
  }
}

// MARK: - Light timing calibration

export const TAP_MINIMUM = 8;
const TAP_MAXIMUM = 32;
/** Taps scattered wider than this (median absolute deviation) are guesses. */
const TAP_MAXIMUM_SPREAD = 0.06;

/**
 * Measures how late the lights land by timing taps against the beat grid.
 * Each tap is made when the person sees a pulse, so its distance from the
 * nearest beat is the lights' lateness plus the person's own lag. The median
 * of enough consistent taps moves the light timing offset by that much.
 *
 * Kept in lockstep with `TapCalibrator` in `LumenDesk/Services/BeatMap.swift`.
 */
export class TapCalibrator {
  private readonly errors: number[] = [];
  private lastTap: number | null = null;

  get count(): number { return this.errors.length; }

  tap(time: number, beatReference: number, interval: number): void {
    if (!(interval >= 0.2 && interval <= 2) || !Number.isFinite(time) || !Number.isFinite(beatReference)) return;
    if (this.lastTap != null && time - this.lastTap < interval * 0.5) return;
    this.lastTap = time;
    const beats = (time - beatReference) / interval;
    // Math.round rounds halves up where Swift rounds them away from zero;
    // only an exact half beat, never a usable tap, can differ.
    this.errors.push((beats - Math.round(beats)) * interval);
    if (this.errors.length > TAP_MAXIMUM) this.errors.splice(0, this.errors.length - TAP_MAXIMUM);
  }

  /** Median lateness once there are enough consistent taps. Positive means the lights land after the beat. */
  get lateness(): number | null {
    if (this.errors.length < TAP_MINIMUM) return null;
    const middle = median(this.errors);
    if (median(this.errors.map(error => Math.abs(error - middle))) > TAP_MAXIMUM_SPREAD) return null;
    return middle;
  }

  /** The offset that would cancel the measured lateness, to the nearest 10 ms and inside the offset's limits. */
  suggestedOffset(current: number, limit = 0.3): number | null {
    const lateness = this.lateness;
    if (lateness == null) return null;
    return Math.max(-limit, Math.min(limit, Math.round((current + lateness) * 100) / 100));
  }

  reset(): void { this.errors.length = 0; this.lastTap = null; }
}

function median(values: readonly number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const n = sorted.length;
  return n % 2 === 1 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

function zScore(values: ArrayLike<number>): Float64Array | null {
  const n = values.length;
  let mean = 0;
  for (let i = 0; i < n; i += 1) mean += values[i];
  mean /= n;
  let square = 0;
  for (let i = 0; i < n; i += 1) square += (values[i] - mean) * (values[i] - mean);
  const deviation = Math.sqrt(square / n);
  if (deviation <= 1e-9) return null;
  const out = new Float64Array(n);
  for (let i = 0; i < n; i += 1) out[i] = (values[i] - mean) / deviation;
  return out;
}

function isSorted(hops: readonly HopFeature[]): boolean {
  for (let i = 1; i < hops.length; i += 1) if (hops[i].time < hops[i - 1].time) return false;
  return true;
}
