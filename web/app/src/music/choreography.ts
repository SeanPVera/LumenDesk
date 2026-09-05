import { normalizeConfiguration } from "./config";
import { FLASH_HARD_CEILING, clamp01, wrapUnit, type AudioReactiveSnapshot, type FixtureRole, type FixtureTopology, type MusicFixtureDescriptor, type MusicLightingFrame, type MusicLightingState, type MusicModeConfiguration, type MusicMovementDirection, type MusicPaletteColor, type MusicSpatialTarget } from "./types";

export class FlashSafetyLimiter {
  static hardMaximumFrequency = FLASH_HARD_CEILING;
  private lastFlashTimestamp: number | null = null;

  admit(timestamp: number, requestedIntensity: number, configuration: MusicModeConfiguration): number {
    const config = normalizeConfiguration(configuration);
    if (
      config.photosensitivitySafeMode ||
      !config.allowsFlashes ||
      config.flashIntensity <= 0 ||
      config.maximumFlashFrequency <= 0 ||
      requestedIntensity <= 0
    ) {
      return 0;
    }
    const frequency = Math.min(FlashSafetyLimiter.hardMaximumFrequency, config.maximumFlashFrequency);
    const minimumInterval = 1 / frequency;
    if (this.lastFlashTimestamp != null && timestamp - this.lastFlashTimestamp + 0.000001 < minimumInterval) {
      return 0;
    }
    this.lastFlashTimestamp = timestamp;
    return Math.min(1, requestedIntensity) * config.flashIntensity;
  }

  reset(): void {
    this.lastFlashTimestamp = null;
  }
}

interface MusicalClock {
  phase: number;
  beatInBar: number;
  interval: number;
  strength: number;
  barRate: number;
  metre: number;
}

export class MusicChoreographyEngine {
  private static outputLatency = 0.045;
  private lastBeatCount = 0;
  private paletteProgress = 0;
  private movementPhase = 0;
  private barsElapsed = 0;
  private highEnergyBeganAt: number | null = null;
  private sustainedEnergyEvent = false;
  private lastTimestamp: number | null = null;
  private brightnessEnvelopes = new Map<string, number>();
  private flashLimiter = new FlashSafetyLimiter();

  reset(): void {
    this.lastBeatCount = 0;
    this.paletteProgress = 0;
    this.movementPhase = 0;
    this.barsElapsed = 0;
    this.highEnergyBeganAt = null;
    this.sustainedEnergyEvent = false;
    this.lastTimestamp = null;
    this.brightnessEnvelopes.clear();
    this.flashLimiter.reset();
  }

  makeFrame(
    snapshot: AudioReactiveSnapshot,
    configuration: MusicModeConfiguration,
    topology: FixtureTopology,
    fixtures: MusicFixtureDescriptor[],
    timestamp: number,
    sequenceNumber: number,
    reducedMotion = false,
  ): MusicLightingFrame {
    const config = normalizeConfiguration(configuration, reducedMotion);
    const targets = expandedTargets(topology, fixtures);
    if (targets.length === 0) {
      return { states: [], timestamp, sequenceNumber, sustainedEnergyEvent: false, flashApplied: false };
    }

    const dt = Math.max(1 / 120, Math.min(0.25, timestamp - (this.lastTimestamp ?? timestamp - 1 / 30)));
    this.lastTimestamp = timestamp;
    const clock = this.musicalClock(snapshot, timestamp);

    const newBeats = snapshot.beatCount > this.lastBeatCount ? snapshot.beatCount - this.lastBeatCount : 0;
    this.lastBeatCount = snapshot.beatCount;
    this.advancePalette(newBeats, clock, config, dt);
    this.advanceMovement(clock, config, dt);

    const beganSustained = this.updateSustainedEnergy(snapshot.energy, timestamp);
    const percussionRequest = Math.max(
      snapshot.snare * config.percussionSensitivity,
      snapshot.percussion * config.percussionSensitivity * 0.9,
    );
    const requestedFlash = Math.max(percussionRequest > 0.62 ? percussionRequest : 0, beganSustained ? 0.8 : 0);
    const flashIntensity = this.flashLimiter.admit(timestamp, requestedFlash, config);

    const silence = snapshot.confidence < 0.025 && snapshot.level < 0.025 && snapshot.energy < 0.035;
    const upperBrightness = Math.max(config.minimumBrightness, config.maximumBrightness * config.masterBrightness);
    const palette = config.palette.map(toHsb);
    const reactivePulse = Math.max(snapshot.beat, snapshot.pulse);
    const musicalPulse = beatShape(clock.phase) * barAccent(clock.beatInBar, clock.metre) * Math.min(1, 0.4 + snapshot.energy * 0.8);
    const pulseDrive = reactivePulse + (musicalPulse - reactivePulse) * clock.strength;
    const phraseLift = config.phraseAware ? Math.max(0, snapshot.energySlope) * 0.22 : 0;
    const chromaHue = chromaToHue(snapshot.chroma);

    const states: MusicLightingState[] = [];
    for (const target of targets) {
      const phase = spatialPhase(target.position, config.movementDirection, this.movementPhase);
      const wave = 0.5 + 0.5 * Math.sin(phase * 2 * Math.PI);
      const stereoBias = 1 + (snapshot.stereo - 0.5) * 2 * config.stereoImage * (target.position - 0.5) * 2;
      const spatialWeight = (1 - config.movementAmount + config.movementAmount * (0.3 + wave * 0.7)) * Math.max(0.55, stereoBias);

      const isHit = target.role === "hit";
      const isAccent = target.role === "accent";
      const isMotion = target.role === "motion";
      const isWash = target.role === "wash" || target.role === "auto";

      const bassDrive = snapshot.bass * config.bassSensitivity;
      const sustain = 0.1 + Math.pow(Math.max(snapshot.level, snapshot.energy), 0.65) * 0.2 + bassDrive * 0.14;
      let swing = pulseDrive * (0.35 + config.beatSensitivity * 0.8);
      if (isHit) swing *= 1.35;
      if (isWash) swing *= 0.72;
      if (isMotion) swing *= 0.9;
      if (isAccent) swing *= 0.55;

      let drive = sustain + swing + phraseLift;
      if (isAccent) drive += snapshot.snare * config.percussionSensitivity * 0.28;
      if (isHit) drive += snapshot.kick * config.bassSensitivity * 0.2;
      drive = Math.min(1, drive * (0.55 + config.effectIntensity * 0.65) * spatialWeight);

      if (silence) {
        if (config.silenceBehavior === "settle") drive = 0;
        else if (config.silenceBehavior === "holdPalette") drive = 0.08 + config.effectIntensity * 0.08;
        else drive = -0.1;
      }

      const rawBrightness = Math.max(
        config.silenceBehavior === "fadeOut" && silence ? 0 : config.minimumBrightness,
        config.minimumBrightness + (upperBrightness - config.minimumBrightness) * Math.max(0, drive),
      );
      const envelopeKey = `${target.fixtureID}#${target.segmentID ?? -1}`;
      const previous = this.brightnessEnvelopes.get(envelopeKey) ?? rawBrightness;
      const attack = 1 - Math.exp(-dt / 0.045);
      const musicalRelease = Math.min(0.3, Math.max(0.06, clock.interval * 0.12));
      const releaseTime = silence ? 0.65 : 0.22 + (musicalRelease - 0.22) * clock.strength;
      const release = 1 - Math.exp(-dt / releaseTime);
      const coefficient = rawBrightness > previous ? attack : release;
      let brightness = previous + (rawBrightness - previous) * coefficient;
      brightness = Math.min(1, brightness + flashIntensity * (1 - brightness));
      this.brightnessEnvelopes.set(envelopeKey, brightness);

      const entries = Math.max(1, palette.length);
      const paletteMotion =
        target.position * config.colorChangeIntensity * Math.max(1, palette.length - 1) +
        this.quantizedPaletteProgress(clock.strength);
      const color = paletteColor(palette, paletteMotion / entries);
      color.hue = wrapUnit(color.hue + (snapshot.mood - 0.5) * 0.08 + chromaHue * 0.04);
      if (isAccent && snapshot.snare * config.percussionSensitivity > 0.42) {
        color.hue = wrapUnit(color.hue + 0.5);
        color.saturation *= 0.72;
      } else if (isHit && snapshot.kick > 0.5) {
        color.saturation = Math.min(1, color.saturation + 0.08);
      }
      if (flashIntensity > 0) color.saturation *= 1 - flashIntensity * 0.8;

      states.push({
        fixtureID: target.fixtureID,
        segmentID: target.segmentID,
        hue: color.hue,
        saturation: clamp01(color.saturation),
        brightness: clamp01(brightness),
        transitionDuration: silence ? 0.55 : flashIntensity > 0 ? 0.04 : 0.1,
        priority: flashIntensity > 0 ? 3 : isHit ? 2 : 1,
      });
    }

    return {
      states,
      timestamp,
      sequenceNumber,
      sustainedEnergyEvent: this.sustainedEnergyEvent,
      flashApplied: flashIntensity > 0,
    };
  }

  private musicalClock(snapshot: AudioReactiveSnapshot, timestamp: number): MusicalClock {
    const interval = snapshot.feltInterval > 0 ? snapshot.feltInterval : snapshot.beatInterval;
    if (!snapshot.isTempoLocked || interval <= 0 || snapshot.beatReferenceTime <= 0) {
      return { phase: 0, beatInBar: 0, interval: 0, strength: 0, barRate: 0, metre: snapshot.metre };
    }
    if (timestamp - snapshot.beatReferenceTime >= interval * 6) {
      return { phase: 0, beatInBar: 0, interval: 0, strength: 0, barRate: 0, metre: snapshot.metre };
    }
    const predicted = timestamp + MusicChoreographyEngine.outputLatency;
    const beats = (predicted - snapshot.beatReferenceTime) / interval;
    const whole = Math.floor(beats);
    const metre = snapshot.metre || 4;
    const beatInBar = ((snapshot.beatInBar + whole) % metre + metre) % metre;
    return {
      phase: beats - whole,
      beatInBar,
      interval,
      strength: Math.max(0, Math.min(1, snapshot.beatConfidence * 1.6)),
      barRate: 1 / (interval * metre),
      metre,
    };
  }

  private updateSustainedEnergy(energy: number, timestamp: number): boolean {
    let began = false;
    if (this.sustainedEnergyEvent) {
      if (energy < 0.5) {
        this.sustainedEnergyEvent = false;
        this.highEnergyBeganAt = null;
      }
    } else if (energy > 0.7) {
      if (this.highEnergyBeganAt == null) this.highEnergyBeganAt = timestamp;
      if (timestamp - (this.highEnergyBeganAt ?? timestamp) >= 0.8) {
        this.sustainedEnergyEvent = true;
        began = true;
      }
    } else if (energy < 0.62) {
      this.highEnergyBeganAt = null;
    }
    return began;
  }

  private advancePalette(newBeats: number, clock: MusicalClock, configuration: MusicModeConfiguration, dt: number): void {
    if (clock.strength > 0 && clock.barRate > 0) {
      const entriesPerBar = 0.25 + configuration.colorChangeIntensity * 1.75;
      this.paletteProgress += entriesPerBar * clock.barRate * dt;
    } else if (newBeats > 0) {
      this.paletteProgress += newBeats * Math.max(0.15, configuration.colorChangeIntensity);
    }
  }

  private quantizedPaletteProgress(strength: number): number {
    if (strength <= 0) return this.paletteProgress;
    const step = Math.floor(this.paletteProgress);
    const fraction = this.paletteProgress - step;
    const crossfade = Math.min(1, fraction / 0.15);
    const quantized = step + crossfade;
    return this.paletteProgress + (quantized - this.paletteProgress) * strength;
  }

  private advanceMovement(clock: MusicalClock, configuration: MusicModeConfiguration, dt: number): void {
    const wallClockRate = 0.18 + configuration.movementSpeed * 1.7;
    let rate = wallClockRate;
    if (clock.strength > 0 && clock.barRate > 0) {
      const traversesPerBar = 0.25 + configuration.movementSpeed * 1.75;
      const musicalRate = traversesPerBar * clock.barRate;
      rate = wallClockRate + (musicalRate - wallClockRate) * clock.strength;
    }
    this.barsElapsed += (clock.barRate > 0 ? clock.barRate : 0.5) * dt;
    if (configuration.movementDirection === "alternating") {
      const bar = clock.strength > 0 ? Math.floor(this.barsElapsed) : Math.floor(this.lastBeatCount / Math.max(1, clock.metre));
      if (bar % 2 !== 0) rate = -rate;
    }
    this.movementPhase += rate * dt;
  }
}

export function expandedTargets(
  topology: FixtureTopology,
  fixtures: MusicFixtureDescriptor[],
): MusicSpatialTarget[] {
  const excluded = new Set(topology.excludedFixtureIDs);
  const byID = new Map(fixtures.map((f) => [f.id, f]));
  const seen = new Set<string>();
  const ordered: MusicFixtureDescriptor[] = [];
  for (const id of topology.fixtureOrder) {
    const fixture = byID.get(id);
    if (fixture && seen.add(id)) ordered.push(fixture);
  }
  const rest = fixtures
    .filter((f) => !seen.has(f.id))
    .sort((a, b) => a.label.localeCompare(b.label, "en", { sensitivity: "base" }) || a.id.localeCompare(b.id));
  ordered.push(...rest);
  const included = ordered.filter((f) => !excluded.has(f.id) && resolveRole(f) !== "off");
  const count = included.reduce((sum, f) => sum + Math.max(1, f.segmentCount || 1), 0);
  if (count === 0) return [];
  const targets: MusicSpatialTarget[] = [];
  let flat = 0;
  for (const fixture of included) {
    const role = resolveRole(fixture);
    const segmentCount = Math.max(1, fixture.segmentCount || 1);
    const segmented = fixture.segmentCount > 0;
    for (let segment = 0; segment < segmentCount; segment += 1) {
      const position =
        topology.layout === "circular"
          ? flat / count
          : count === 1
            ? 0.5
            : flat / (count - 1);
      targets.push({
        fixtureID: fixture.id,
        segmentID: segmented ? segment : null,
        position,
        role,
      });
      flat += 1;
    }
  }
  return targets;
}

export function resolveRole(fixture: MusicFixtureDescriptor): FixtureRole {
  if (fixture.role !== "auto") return fixture.role;
  if (fixture.segmentCount >= 8) return "motion";
  if (fixture.segmentCount > 0) return "motion";
  if (fixture.id.includes("kick") || fixture.label.toLowerCase().includes("downstage")) return "hit";
  if (fixture.id.includes("accent") || fixture.label.toLowerCase().includes("rear")) return "accent";
  return "wash";
}

function beatShape(phase: number): number {
  const decay = Math.pow(Math.max(0, 1 - phase), 2.6);
  const anticipation = phase > 0.82 ? Math.pow((phase - 0.82) / 0.18, 2) * 0.55 : 0;
  return Math.max(decay, anticipation);
}

function barAccent(beatInBar: number, metre: number): number {
  if (beatInBar === 0) return 1;
  if (metre === 3) return beatInBar === 1 ? 0.7 : 0.82;
  if (metre === 5) return beatInBar === 3 ? 0.9 : 0.7;
  if (metre === 6) return beatInBar === 3 ? 0.9 : 0.72;
  if (metre === 7) return beatInBar === 3 || beatInBar === 5 ? 0.88 : 0.7;
  if (beatInBar === 2) return 0.88;
  return 0.74;
}

function spatialPhase(position: number, direction: MusicMovementDirection, time: number): number {
  switch (direction) {
    case "forward":
    case "clockwise":
    case "alternating":
      return position - time;
    case "reverse":
    case "counterclockwise":
      return position + time;
    case "expanding":
      return Math.abs(position - 0.5) * 2 - time;
    case "contracting":
      return Math.abs(position - 0.5) * 2 + time;
  }
}

interface HSB {
  hue: number;
  saturation: number;
  brightness: number;
}

function toHsb(color: MusicPaletteColor): HSB {
  const r = ((color.hex >> 16) & 0xff) / 255;
  const g = ((color.hex >> 8) & 0xff) / 255;
  const b = (color.hex & 0xff) / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  let hue = 0;
  if (delta !== 0) {
    if (max === r) hue = (((g - b) / delta) % 6) / 6;
    else if (max === g) hue = (b - r) / delta / 6 + 1 / 3;
    else hue = (r - g) / delta / 6 + 2 / 3;
  }
  return { hue: wrapUnit(hue), saturation: max === 0 ? 0 : delta / max, brightness: max };
}

function paletteColor(palette: HSB[], position: number): HSB {
  if (palette.length === 0) return { hue: 0, saturation: 0, brightness: 1 };
  if (palette.length === 1) return { ...palette[0] };
  const wrapped = wrapUnit(position) * (palette.length - 1);
  const index = Math.floor(wrapped);
  const t = wrapped - index;
  const a = palette[index];
  const b = palette[Math.min(palette.length - 1, index + 1)];
  return {
    hue: lerpHue(a.hue, b.hue, t),
    saturation: a.saturation + (b.saturation - a.saturation) * t,
    brightness: a.brightness + (b.brightness - a.brightness) * t,
  };
}

function lerpHue(a: number, b: number, t: number): number {
  let delta = wrapUnit(b - a + 0.5) - 0.5;
  return wrapUnit(a + delta * t);
}

function chromaToHue(chroma: number[]): number {
  if (chroma.length < 12) return 0;
  let best = 0;
  let idx = 0;
  for (let i = 0; i < 12; i += 1) {
    if (chroma[i] > best) {
      best = chroma[i];
      idx = i;
    }
  }
  return best > 0.15 ? idx / 12 : 0;
}
