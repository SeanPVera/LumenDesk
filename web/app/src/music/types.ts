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

export type MusicTransportKind = "lifxLAN" | "goveeLAN" | "goveeRealtimeSegments";

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
