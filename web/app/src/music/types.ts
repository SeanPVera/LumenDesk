export type MusicModePreset =
  | "ambient"
  | "balanced"
  | "concert"
  | "cinematic"
  | "soundcheck"
  | "club"
  | "halftime"
  | "waltz"
  | "custom";

export type MusicMovementDirection =
  | "forward"
  | "reverse"
  | "alternating"
  | "expanding"
  | "contracting"
  | "clockwise"
  | "counterclockwise";

export type MusicSilenceBehavior = "settle" | "holdPalette" | "fadeOut";

export type FixtureTopologyLayout = "leftToRight" | "frontToBack" | "circular" | "custom";

// Mirrors MusicTransportKind in MusicMode.swift. The browser has no per-panel
// Shapes stream, so a Shapes wall is always "nanoleafLAN" here.
export type MusicTransportKind = "lifxLAN" | "goveeLAN" | "nanoleafLAN" | "goveeRealtimeSegments";

export type FixtureRole = "auto" | "wash" | "hit" | "accent" | "motion" | "off";

export type TimeFeel = "auto" | "straight" | "half" | "double";

export type Metre = 3 | 4 | 5 | 6 | 7;

export type AudioSourceKind = "demo" | "microphone" | "file" | "display" | "midi";

export interface MusicPaletteColor {
  hex: number;
}

export interface MusicModeConfiguration {
  preset: MusicModePreset;
  masterBrightness: number;
  effectIntensity: number;
  beatSensitivity: number;
  bassSensitivity: number;
  percussionSensitivity: number;
  colorChangeIntensity: number;
  movementAmount: number;
  movementDirection: MusicMovementDirection;
  movementSpeed: number;
  minimumBrightness: number;
  maximumBrightness: number;
  allowsFlashes: boolean;
  flashIntensity: number;
  maximumFlashFrequency: number;
  palette: MusicPaletteColor[];
  silenceBehavior: MusicSilenceBehavior;
  photosensitivitySafeMode: boolean;
  restorePreviousState: boolean;
  metreOverride: Metre | "auto";
  timeFeel: TimeFeel;
  stereoImage: number;
  phraseAware: boolean;
  /** Seconds the show runs ahead of the beat to make up for slow lights.
   * Positive lands accents earlier; it adds to the engine's fixed 45 ms. */
  outputLatencyOffset: number;
}

/** One analysis hop's features, used to build and align beat maps. */
export interface HopFeature {
  /** Seconds: stream time while analysing, track position once stored. */
  time: number;
  /** The beat tracker's onset input (broadband onset mixed with kick). */
  onset: number;
  kick: number;
  energy: number;
}

export interface BeatGrid {
  tempo: number;
  interval: number;
  confidence: number;
  lastBeatTime: number;
  beatInBar: number;
  beatCount: number;
  isLocked: boolean;
  metre: Metre;
  metreConfidence: number;
  timeFeel: TimeFeel;
  feltInterval: number;
  feltTempo: number;
}

export const SPECTRUM_BINS = 32;

export function emptySpectrum(): number[] {
  return Array.from({ length: SPECTRUM_BINS }, () => 0);
}

export interface AudioReactiveSnapshot {
  level: number;
  beat: number;
  kick: number;
  snare: number;
  percussion: number;
  bass: number;
  mids: number;
  highs: number;
  energy: number;
  mood: number;
  confidence: number;
  pulse: number;
  drop: number;
  beatCount: number;
  tempo: number;
  beatInterval: number;
  beatConfidence: number;
  beatReferenceTime: number;
  beatInBar: number;
  isTempoLocked: boolean;
  metre: Metre;
  metreConfidence: number;
  timeFeel: TimeFeel;
  feltInterval: number;
  feltTempo: number;
  stereo: number;
  chroma: number[];
  spectrum: number[];
  phrasePosition: number;
  energySlope: number;
  sourceDescription: string;
  analysisTimestamp?: number;
  analysisCompletedAt?: number;
  freshnessGrace?: number;
  rawRMS?: number;
  onset?: number;
  gridBeatPosition?: number;
  analyzedSamples?: number;
  droppedBuffers?: number;
  /** 0…1 energy of the current bar, known in advance when a beat map plays. */
  barEnergy?: number;
  /** True when the grid fields come from a beat map rather than live inference. */
  beatMapActive?: boolean;
}

export function emptySnapshot(): AudioReactiveSnapshot {
  return {
    level: 0,
    beat: 0,
    kick: 0,
    snare: 0,
    percussion: 0,
    bass: 0,
    mids: 0,
    highs: 0,
    energy: 0,
    mood: 0.5,
    confidence: 0,
    pulse: 0,
    drop: 0,
    beatCount: 0,
    tempo: 0,
    beatInterval: 0,
    beatConfidence: 0,
    beatReferenceTime: 0,
    beatInBar: 0,
    isTempoLocked: false,
    metre: 4,
    metreConfidence: 0,
    timeFeel: "straight",
    feltInterval: 0,
    feltTempo: 0,
    stereo: 0.5,
    chroma: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    spectrum: emptySpectrum(),
    phrasePosition: 0,
    energySlope: 0,
    sourceDescription: "Idle",
  };
}

export interface MusicFixtureDescriptor {
  id: string;
  label: string;
  transport: MusicTransportKind;
  segmentCount: number;
  role: FixtureRole;
}

export interface FixtureTopology {
  layout: FixtureTopologyLayout;
  fixtureOrder: string[];
  excludedFixtureIDs: string[];
}

export interface MusicSpatialTarget {
  fixtureID: string;
  segmentID: number | null;
  position: number;
  role: FixtureRole;
}

export interface MusicLightingState {
  fixtureID: string;
  segmentID: number | null;
  hue: number;
  saturation: number;
  brightness: number;
  transitionDuration: number;
  priority: number;
}

export interface MusicLightingFrame {
  states: MusicLightingState[];
  timestamp: number;
  sequenceNumber: number;
  sustainedEnergyEvent: boolean;
  flashApplied: boolean;
  /** 0…5 energy gear the frame was rendered in. */
  energyTier?: number;
}

export const SOUNDCHECK_PALETTE: MusicPaletteColor[] = [
  { hex: 0xff3b9d },
  { hex: 0x7d5cff },
  { hex: 0x16d9d0 },
  { hex: 0xffb52e },
];

export const AURORA_PALETTE: MusicPaletteColor[] = [
  { hex: 0x38e8d4 },
  { hex: 0x6d7cff },
  { hex: 0xb65cff },
  { hex: 0x2ea9ff },
];

export const SUNSET_PALETTE: MusicPaletteColor[] = [
  { hex: 0xffd08a },
  { hex: 0xff8a4c },
  { hex: 0xe34c73 },
  { hex: 0x753b8f },
];

export const OCEAN_PALETTE: MusicPaletteColor[] = [
  { hex: 0x56e0d5 },
  { hex: 0x22afcf },
  { hex: 0x2867c7 },
  { hex: 0x15366e },
];

export const CLUB_PALETTE: MusicPaletteColor[] = [
  { hex: 0xff2d6a },
  { hex: 0x7c5cff },
  { hex: 0x21c4de },
  { hex: 0xf6faff },
];

export function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}

export function wrapUnit(value: number): number {
  const wrapped = value % 1;
  return wrapped < 0 ? wrapped + 1 : wrapped;
}

export const FLASH_HARD_CEILING = 3;

export function synthSpectrum(
  kick: number,
  snare: number,
  hat: number,
  energy: number,
  elapsed = 0,
): number[] {
  const bins = emptySpectrum();
  for (let i = 0; i < SPECTRUM_BINS; i += 1) {
    const x = i / (SPECTRUM_BINS - 1);
    const bass = kick * Math.exp(-x * 9);
    const body = energy * 0.2 * Math.exp(-((x - 0.2) * (x - 0.2)) / 0.022);
    const mid = snare * Math.exp(-((x - 0.38) * (x - 0.38)) / 0.016);
    const shimmer = 0.55 + 0.45 * Math.sin(elapsed * 17 + i * 0.7);
    const high = hat * Math.max(0, (x - 0.5) / 0.5) * shimmer;
    bins[i] = Math.min(1, bass + body + mid + high);
  }
  return bins;
}

/** Matches AudioReactiveSnapshot.fresh; no raw PCM is retained for diagnostics. */
export function freshSnapshot(input: AudioReactiveSnapshot, timestamp: number): AudioReactiveSnapshot {
  if (input.analysisTimestamp == null) return input;
  const age = Math.max(0, timestamp - input.analysisTimestamp);
  const weight = clamp01(1 - (age - (input.freshnessGrace ?? .25)));
  const next = { ...input };
  for (const key of ['level','energy','confidence','bass','mids','highs','beatConfidence'] as const) next[key] *= weight;
  // A delayed or repeated snapshot still carries a loudness estimate, but its
  // one-hop transients must not restart an accent on each render tick.
  const transientWeight = weight * Math.exp(-age / .08);
  for (const key of ['beat','kick','snare','percussion'] as const) next[key] *= transientWeight;
  if (next.onset != null) next.onset *= transientWeight;
  const pulseDecay = input.isTempoLocked && input.beatInterval > 0 ? Math.min(.34, Math.max(.1, input.beatInterval * .42)) : .16;
  next.pulse *= weight * Math.exp(-age / pulseDecay);
  next.drop *= weight * Math.exp(-age / .3);
  if (weight === 0) { next.isTempoLocked = false; next.tempo = 0; next.beatMapActive = false; next.barEnergy = undefined; }
  return next;
}

/** Retain hits that arrived since the previous render while keeping the newest
 * loudness and grid. Exponential aging composes across capture/publication
 * boundaries; the ordinary freshness policy is applied once when rendering. */
export function retainUnrenderedTransients(
  next: AudioReactiveSnapshot,
  previous: AudioReactiveSnapshot | undefined,
): AudioReactiveSnapshot {
  if (previous?.analysisTimestamp == null || next.analysisTimestamp == null ||
      previous.analysisTimestamp > next.analysisTimestamp) return next;
  // A new sample clock or a reported capture gap ends the old stream even
  // when its host timestamps remain monotonic. Do not carry its last hit over.
  if ((previous.analyzedSamples ?? 0) > 0 && (next.analyzedSamples ?? 0) > 0 &&
      next.analyzedSamples! <= previous.analyzedSamples!) return next;
  if ((next.droppedBuffers ?? 0) > (previous.droppedBuffers ?? 0)) return next;
  const decay = Math.exp(-(next.analysisTimestamp - previous.analysisTimestamp) / .08);
  let combined = next;
  for (const key of ['beat', 'kick', 'snare', 'percussion', 'onset'] as const) {
    const held = (previous[key] ?? 0) * decay;
    if (held > (next[key] ?? 0)) {
      if (combined === next) combined = { ...next };
      combined[key] = held;
    }
  }
  return combined;
}
