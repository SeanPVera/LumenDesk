import { normalizeConfiguration } from "./config";
import { FLASH_HARD_CEILING, clamp01, wrapUnit, type AudioReactiveSnapshot, type FixtureRole, type FixtureTopology, type MusicFixtureDescriptor, type MusicLightingFrame, type MusicLightingState, type MusicModeConfiguration, type MusicMovementDirection, type MusicPaletteColor, type MusicSpatialTarget, freshSnapshot } from "./types";

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
  /** Absolute position in bars on the detected grid. */
  barPosition: number;
}

/** One-pole follower toward `target` over `timeConstant` seconds. */
function follow(current: number, target: number, dt: number, timeConstant: number): number {
  if (!(timeConstant > 0)) return target;
  return current + (target - current) * (1 - Math.exp(-dt / timeConstant));
}

/**
 * Brightness is a **bed plus a swell**: the bed tracks loudness over about half
 * a second and carries dynamics, the swell is an accent inside the headroom
 * above it and carries rhythm. A fixture falls back to the bed rather than to
 * the floor, so a beat reads as an accent on a lit room instead of the room
 * going dark and coming back.
 *
 * Kept in lockstep with `LumenDesk/Services/MusicChoreographyEngine.swift`.
 */
export class MusicChoreographyEngine {
  private static outputLatency = 0.045;
  private static attackTime = 0.026;
  private static bedTimeConstant = 0.55;
  private static offGridRelease = 0.28;
  private lastBeatCount = 0;
  private paletteProgress = 0;
  private movementPhase = 0;
  private barsElapsed = 0;
  private highEnergyBeganAt: number | null = null;
  private sustainedEnergyEvent = false;
  private lastTimestamp: number | null = null;
  private brightnessEnvelopes = new Map<string, number>();
  private flashLimiter = new FlashSafetyLimiter();
  private dynamics = 0;
  private fastEnergy = 0;
  private slowEnergy = 0;
  private onsetEnvelope = 0;
  private accentEnvelope = 0;
  private lastPaletteHold: number | null = null;
  private paletteFadeFrom = 0;
  private paletteFadeTo = 0;
  private paletteFadeBar = 0;

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
    this.dynamics = 0;
    this.fastEnergy = 0;
    this.slowEnergy = 0;
    this.onsetEnvelope = 0;
    this.accentEnvelope = 0;
    this.lastPaletteHold = null;
    this.paletteFadeFrom = this.paletteFadeTo = this.paletteFadeBar = 0;
  }

  makeFrame(
    input: AudioReactiveSnapshot,
    configuration: MusicModeConfiguration,
    topology: FixtureTopology,
    fixtures: MusicFixtureDescriptor[],
    timestamp: number,
    sequenceNumber: number,
    reducedMotion = false,
  ): MusicLightingFrame {
    const snapshot = freshSnapshot(input, timestamp);
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

    const silence = snapshot.confidence < 0.025 && snapshot.level < 0.025 && snapshot.energy < 0.035;

    // One loudness line, smoothed over about half a second, so a single noisy
    // analysis hop cannot move the room.
    const loudness = Math.max(snapshot.level, snapshot.energy);
    this.dynamics = follow(this.dynamics, loudness, dt, silence ? 0.9 : MusicChoreographyEngine.bedTimeConstant);
    // A long/short energy pair. Their difference is a phrase building, where
    // the single-hop energy difference this replaces was measurement noise.
    this.fastEnergy = follow(this.fastEnergy, snapshot.energy, dt, 0.7);
    this.slowEnergy = follow(this.slowEnergy, snapshot.energy, dt, 5);
    const energyRise = Math.max(0, this.fastEnergy - this.slowEnergy);

    this.advancePalette(newBeats, clock, config, dt);
    this.advanceMovement(clock, config, dt);

    const beganSustained = this.updateSustainedEnergy(this.fastEnergy, timestamp);
    const percussionRequest = Math.max(
      snapshot.snare * config.percussionSensitivity,
      snapshot.percussion * config.percussionSensitivity * 0.9,
    );
    const requestedFlash = Math.max(percussionRequest > 0.62 ? percussionRequest : 0, beganSustained ? 0.8 : 0);
    const flashIntensity = this.flashLimiter.admit(timestamp, requestedFlash, config);

    // On the grid a pulse is a contour across the felt beat. Off it, a
    // smoothed onset envelope with a bounded fall, so a wall of hi-hats raises
    // a level rather than retriggering a pulse several times a second.
    this.onsetEnvelope = Math.max(
      this.onsetEnvelope * Math.exp(-dt / MusicChoreographyEngine.offGridRelease),
      Math.max(snapshot.beat, snapshot.pulse),
    );
    const musicalPulse = beatShape(clock.phase) * barAccent(clock.beatInBar, clock.metre);
    const pulseDrive = this.onsetEnvelope + (musicalPulse - this.onsetEnvelope) * clock.strength;

    const accentTarget = clamp01(snapshot.snare * config.percussionSensitivity);
    this.accentEnvelope = Math.max(this.accentEnvelope * Math.exp(-dt / 0.35), accentTarget);

    // How deep a beat may dig, as a fraction of the headroom above the bed. It
    // shrinks at fast tempos so the rate of *visible* musical events stays
    // musical however fast analysis and frame delivery run.
    const feltInterval = clock.interval > 0 ? clock.interval : 0.5;
    const tempoRestraint = clamp01((feltInterval - 0.22) / 0.26);
    const dynamicsGate = Math.pow(clamp01(this.dynamics), 1.5);
    const baseDepth =
      (config.beatSensitivity * 1.57) *
      (0.6 + config.effectIntensity * 0.4) * Math.min(1, config.effectIntensity / 0.2) *
      (0.4 + 0.6 * tempoRestraint) *
      (0.12 + 0.88 * dynamicsGate);

    const lowerBrightness = config.minimumBrightness * config.masterBrightness;
    const upperBrightness = config.maximumBrightness * config.masterBrightness;
    const palette = config.palette.map(toHsb);
    const phraseLift = config.phraseAware ? Math.min(0.18, energyRise * 0.9) : 0;

    // A room of two or three bulbs cannot show travel, so a sweep there is one
    // more brightness wobble. Spend movement on colour position instead; a
    // segmented fixture gets the full spatial treatment.
    const resolution = targets.length;
    const spatialFidelity = resolution >= 8 ? 1 : resolution >= 4 ? 0.6 : 0.3;
    const motionDepth = config.movementAmount * spatialFidelity;

    const states: MusicLightingState[] = [];
    for (const target of targets) {
      const phase = spatialPhase(topology.layout === "circular" ? target.position : target.position * 0.75, config.movementDirection, this.movementPhase);
      const wave = 0.5 + 0.5 * Math.sin(phase * 2 * Math.PI);
      const stereoBias = 1 + (snapshot.stereo - 0.5) * 2 * config.stereoImage * (target.position - 0.5) * 2;
      // Centred on 1 so movement tilts the room rather than dimming it.
      const spatialWeight = (1 - motionDepth * 0.5 + motionDepth * wave) * Math.max(0.6, Math.min(1.4, stereoBias));

      const isHit = target.role === "hit";
      const isAccent = target.role === "accent";
      const isMotion = target.role === "motion";
      const isWash = target.role === "wash" || target.role === "auto";

      // The bed: where this fixture rests between accents.
      const bassBed = snapshot.bass * config.bassSensitivity * 0.1;
      const sustainedLift = config.phraseAware && this.sustainedEnergyEvent ? 0.06 + this.fastEnergy * 0.08 : 0;
      let bedLevel = 0.1 + Math.pow(clamp01(this.dynamics), 0.7) * 0.4 + bassBed + phraseLift + sustainedLift;
      // A hit fixture rests darker so it has headroom to punch.
      if (isHit) bedLevel *= 0.76;
      else if (isAccent) bedLevel *= 0.85;
      bedLevel = clamp01(bedLevel * (0.6 + config.effectIntensity * 0.5) * spatialWeight);

      // The swell: an accent inside the headroom above the bed.
      let depth = baseDepth;
      if (isHit) depth *= 1.7;
      else if (isWash) depth *= 1.15;
      else if (isMotion) depth *= 0.92;
      else if (isAccent) depth *= 0.6;
      if (isAccent) depth += this.accentEnvelope * 0.18 * config.effectIntensity * config.beatSensitivity;
      if (isHit) depth += snapshot.kick * config.bassSensitivity * 0.1 * config.effectIntensity * config.beatSensitivity;
      // Same soft headroom curve as the native engine.
      depth = 1 - Math.exp(-Math.max(0, depth) * 1.6);

      const bed = lowerBrightness + (upperBrightness - lowerBrightness) * bedLevel;
      const p = clamp01(pulseDrive);
      const rolePulse = isHit ? Math.min(1, p + 2 * Math.max(0, p - 0.35) * (1 - p)) : p;
      let rawBrightness = bed + (upperBrightness - bed) * depth * rolePulse;

      if (silence) {
        if (config.silenceBehavior === "settle") rawBrightness = lowerBrightness;
        else if (config.silenceBehavior === "holdPalette") {
          rawBrightness =
            lowerBrightness +
            (upperBrightness - lowerBrightness) * (0.08 + config.effectIntensity * 0.08);
        } else rawBrightness = 0;
      }
      rawBrightness = Math.max(
        silence && config.silenceBehavior === "fadeOut" ? 0 : lowerBrightness,
        Math.min(upperBrightness, rawBrightness),
      );

      const envelopeKey = `${target.fixtureID}#${target.segmentID ?? -1}`;
      const previous = this.brightnessEnvelopes.get(envelopeKey) ?? rawBrightness;
      const attack = 1 - Math.exp(-dt / MusicChoreographyEngine.attackTime);
      // Release is a fraction of the felt beat with a floor. The constant this
      // replaces clamped to 60 ms for anything at or above 120 BPM, turning
      // every beat into a full-depth sawtooth.
      const musicalRelease = Math.min(0.45, Math.max(0.13, feltInterval * 0.26));
      const quietStretch = 1 + Math.max(0, 0.6 - clamp01(this.dynamics)) * 1.2;
      const releaseTime = silence ? 0.8 : musicalRelease * quietStretch;
      const release = 1 - Math.exp(-dt / releaseTime);
      const coefficient = rawBrightness > previous ? attack : release;
      let brightness = previous + (rawBrightness - previous) * coefficient;
      brightness += flashIntensity * Math.max(0, upperBrightness - brightness);
      brightness = Math.max(silence && config.silenceBehavior === "fadeOut" ? 0 : lowerBrightness, Math.min(upperBrightness, brightness));
      this.brightnessEnvelopes.set(envelopeKey, brightness);

      // A palette entry held for a whole number of bars and cross-faded over
      // one beat at the bar line, plus a spatial offset so the room reads as
      // one gradient.
      const spread = config.colorChangeIntensity * (0.35 + spatialFidelity * 0.65);
      const paletteMotion =
        target.position * spread * Math.max(1, palette.length - 1) + this.paletteProgress + (isAccent && palette.length > 1 ? 1 : 0);
      const color = paletteColor(palette, paletteMotion / Math.max(1, palette.length));
      if (flashIntensity > 0) color.saturation *= 1 - flashIntensity * 0.8;

      states.push({
        fixtureID: target.fixtureID,
        segmentID: target.segmentID,
        hue: color.hue,
        saturation: clamp01(color.saturation),
        brightness: clamp01(brightness),
        // The transition covers the gap to the next frame, so a fixture
        // interpolates between commands instead of stepping.
        transitionDuration: silence ? 0.55 : flashIntensity > 0 ? 0.04 : 0.09,
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
    const metre = snapshot.metre || 4;
    const blank: MusicalClock = {
      phase: 0, beatInBar: 0, interval: 0, strength: 0, barRate: 0, metre, barPosition: 0,
    };
    if (!snapshot.isTempoLocked || interval <= 0 || snapshot.beatReferenceTime <= 0) return blank;
    if (timestamp - snapshot.beatReferenceTime >= interval * 6) return blank;

    // Compensate for transport, firmware delay, and the envelope's own rise
    // time, or the swell lands consistently late.
    const predicted =
      timestamp + MusicChoreographyEngine.outputLatency + MusicChoreographyEngine.attackTime * 0.8;
    const gridInterval = snapshot.beatInterval > 0 ? snapshot.beatInterval : interval;
    const gridBeats = (predicted - snapshot.beatReferenceTime) / gridInterval;
    // The reference advances on every detected beat. Include its position on
    // the grid before dividing into felt beats, or half-time restarts its
    // pulse halfway through every cycle.
    const absoluteBeat = (snapshot.gridBeatPosition ?? snapshot.beatCount) + gridBeats;
    const beats = (absoluteBeat * gridInterval) / interval;
    const whole = Math.floor(beats);
    const beatInBar = (((snapshot.beatInBar + Math.floor(gridBeats)) % metre) + metre) % metre;
    return {
      phase: beats - whole,
      beatInBar,
      interval,
      // Confidence now reflects how far the tempo estimate is ahead of its
      // nearest rival period, so this cross-fade does real work: an ambiguous
      // grid renders the smooth energy-driven show instead of a confident
      // wrong one.
      strength: clamp01((snapshot.beatConfidence - 0.25) / 0.45),
      barRate: 1 / (gridInterval * metre),
      metre,
      barPosition: absoluteBeat / metre,
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

  /**
   * Palette progression measured in whole bars: an entry is held for an integer
   * number of bars and cross-faded across one beat at the bar line, so the
   * change lands on a downbeat by construction. The free-running accumulator
   * this replaces quantized to its own boundaries, which drifted relative to
   * the bar and changed colour about twice a second at the default setting.
   */
  private advancePalette(_newBeats: number, clock: MusicalClock, configuration: MusicModeConfiguration, dt: number): void {
    if (configuration.colorChangeIntensity <= 0) { this.lastPaletteHold = null; return; }
    if (clock.strength > 0 && clock.barRate > 0) {
      const barsPerColour = Math.max(1,Math.round(5-configuration.colorChangeIntensity*4));
      const hold = Math.floor(clock.barPosition/barsPerColour);
      if (this.lastPaletteHold != null && hold !== this.lastPaletteHold) {
        this.paletteFadeFrom=this.paletteProgress;this.paletteFadeTo=this.paletteProgress+1;this.paletteFadeBar=clock.barPosition;
      } else if (this.lastPaletteHold == null) {
        this.paletteFadeFrom=this.paletteFadeTo=this.paletteProgress;this.paletteFadeBar=clock.barPosition;
      }
      this.lastPaletteHold=hold;
      const blend=clamp01((clock.barPosition-this.paletteFadeBar)*clock.metre);
      this.paletteProgress=this.paletteFadeFrom+(this.paletteFadeTo-this.paletteFadeFrom)*blend;
    } else {
      this.lastPaletteHold=null;
      this.paletteProgress+=dt*configuration.colorChangeIntensity*.08;
    }
  }

  private advanceMovement(clock: MusicalClock, configuration: MusicModeConfiguration, dt: number): void {
    if (configuration.movementSpeed <= 0 || configuration.movementAmount <= 0) return;
    const wallClockRate = configuration.movementSpeed * 0.66;
    let rate = wallClockRate;
    if (clock.strength > 0 && clock.barRate > 0) {
      // One traverse every few bars at the default speed: motion that reads as
      // travel rather than as another oscillator stacked on brightness.
      const traversesPerBar = 0.12 + configuration.movementSpeed * 0.55;
      const musicalRate = traversesPerBar * clock.barRate;
      rate = wallClockRate + (musicalRate - wallClockRate) * clock.strength;
    }
    this.barsElapsed += (clock.barRate > 0 ? clock.barRate : 0.5) * dt;
    if (configuration.movementDirection === "alternating") {
      const bar = clock.strength > 0 ? Math.floor(clock.barPosition) : Math.floor(this.lastBeatCount / Math.max(1, clock.metre));
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
    if (fixture && !seen.has(id)) { seen.add(id); ordered.push(fixture); }
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

/**
 * Brightness contour across one felt beat. Unlike the curve it replaces this
 * returns to a floor rather than to zero, so a beat is an accent on a lit room
 * instead of the room going dark and coming back.
 */
function beatShape(phase: number): number {
  const decay = Math.pow(Math.max(0, 1 - phase), 2);
  const anticipation = phase > 0.86 ? Math.pow((phase - 0.86) / 0.14, 2) * 0.62 : 0;
  return 0.07 + 0.93 * Math.max(decay, anticipation);
}

/**
 * Relative weight of each beat in the bar. The downbeat leads by a clear
 * margin, so only the strong beats produce a large swing and the bar reads as
 * a groove rather than a metronome at full depth.
 */
function barAccent(beatInBar: number, metre: number): number {
  if (beatInBar === 0) return 1;
  if (metre === 3) return beatInBar === 1 ? 0.46 : 0.6;
  if (metre === 5) return beatInBar === 3 ? 0.72 : 0.46;
  if (metre === 6) return beatInBar === 3 ? 0.72 : 0.48;
  if (metre === 7) return beatInBar === 3 || beatInBar === 5 ? 0.7 : 0.46;
  if (beatInBar === 2) return 0.72;
  return 0.5;
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
  // Cyclic, matching the Swift engine. A clamped ramp reaches the last entry
  // and snaps back to the first, which the native app never did.
  const wrapped = wrapUnit(position) * palette.length;
  const index = Math.floor(wrapped) % palette.length;
  const t = wrapped - Math.floor(wrapped);
  const a = palette[index];
  const b = palette[(index + 1) % palette.length];
  return {
    hue: a.saturation <= 0.08 ? b.hue : b.saturation <= 0.08 ? a.hue : lerpHue(a.hue, b.hue, t),
    saturation: a.saturation + (b.saturation - a.saturation) * t,
    brightness: a.brightness + (b.brightness - a.brightness) * t,
  };
}

function lerpHue(a: number, b: number, t: number): number {
  let delta = wrapUnit(b - a + 0.5) - 0.5;
  return wrapUnit(a + delta * t);
}
