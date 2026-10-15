import { normalizeConfiguration } from "./config";
import { FLASH_HARD_CEILING, clamp01, wrapUnit, type AudioReactiveSnapshot, type FixtureRole, type FixtureTopology, type MusicFixtureDescriptor, type MusicLightingFrame, type MusicLightingState, type MusicModeConfiguration, type MusicMovementDirection, type MusicPaletteColor, type MusicSpatialTarget, freshSnapshot } from "./types";

export class FlashSafetyLimiter {
  static hardMaximumFrequency = FLASH_HARD_CEILING;
  private lastFlashTimestamp: number | null = null;

  admit(timestamp: number, requestedIntensity: number, configuration: MusicModeConfiguration): number {
    const config = configuration;
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
    return Math.min(1, requestedIntensity) * clamp01(config.flashIntensity);
  }

  reset(): void {
    this.lastFlashTimestamp = null;
  }
}

interface MusicalClock {
  /** Absolute position in felt beats; its whole part counts beats. */
  beatPosition: number;
  phase: number;
  beatInBar: number;
  interval: number;
  strength: number;
  barRate: number;
  metre: number;
  /** Absolute position in bars on the detected grid. */
  barPosition: number;
}

/** Depth of the beat swell in each energy tier. Tier 3 is the engine's original depth. */
const TIER_DEPTH = [0.62, 0.74, 0.87, 1, 1.08, 1.15];
/** Rise time per tier: calm music eases into a swell, loud music snaps. */
const TIER_ATTACK = [0.14, 0.14, 0.07, 0.026, 0.026, 0.026];

/**
 * Six energy gears, 0…5, with hysteresis so a bar sitting on a boundary does
 * not flip the show back and forth. A beat map supplies the current bar's
 * energy before it plays; live input can only report the bar just finished,
 * so live tiers lag by one bar. Without a grid, a two-second energy average
 * stands in for the bar.
 */
export class EnergyTierTracker {
  private tierValue = -1;
  private barIndex: number | null = null;
  private barSum = 0;
  private barTime = 0;
  private longEnergy = 0;
  private freeEnergy = 0;
  private primed = false;

  /** The current tier; 3 until the first measurement, which is the engine's original behaviour. */
  get tier(): number { return this.tierValue < 0 ? 3 : this.tierValue; }

  update(energy: number, dt: number, barPosition: number, gridStrength: number, mappedBarEnergy?: number): number {
    if (!this.primed) { this.longEnergy = energy; this.freeEnergy = energy; this.primed = true; }
    this.longEnergy = follow(this.longEnergy, energy, dt, 20);
    if (mappedBarEnergy != null && Number.isFinite(mappedBarEnergy)) {
      this.barIndex = null;
      this.applyTarget(clamp01(mappedBarEnergy));
      return this.tier;
    }
    if (gridStrength > 0 && Number.isFinite(barPosition)) {
      const bar = Math.floor(barPosition);
      if (this.barIndex == null) {
        this.barIndex = bar; this.barSum = 0; this.barTime = 0;
      } else if (bar !== this.barIndex) {
        if (this.barTime >= 0.2) this.applyTarget(this.liveTarget(this.barSum / this.barTime));
        this.barIndex = bar; this.barSum = 0; this.barTime = 0;
      }
      this.barSum += energy * dt;
      this.barTime += dt;
      return this.tier;
    }
    this.barIndex = null;
    this.freeEnergy = follow(this.freeEnergy, energy, dt, 2);
    this.applyTarget(this.liveTarget(this.freeEnergy));
    return this.tier;
  }

  reset(): void {
    this.tierValue = -1; this.barIndex = null; this.barSum = this.barTime = 0;
    this.longEnergy = this.freeEnergy = 0; this.primed = false;
  }

  /** Same 60/40 absolute/relative split a beat map uses for its bars. */
  private liveTarget(mean: number): number {
    return clamp01(0.6 * clamp01(mean / 0.75) + 0.4 * clamp01(0.5 + (mean - this.longEnergy) / 0.25));
  }

  private applyTarget(target: number): void {
    const x = target * 5;
    if (this.tierValue < 0) { this.tierValue = Math.max(0, Math.min(5, Math.round(x))); return; }
    while (this.tierValue < 5 && x >= this.tierValue + 0.65) this.tierValue += 1;
    while (this.tierValue > 0 && x < this.tierValue - 0.65) this.tierValue -= 1;
  }
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
  /** Whether the palette is currently stepping per beat (high tiers) or per bar. */
  private paletteHoldsBeats = false;
  private readonly tiers = new EnergyTierTracker();
  private lastClockBeatInBar: number | null = null;
  // Copy cache inputs: live controls may edit their arrays and descriptors in
  // place, so reference identity alone cannot safely invalidate the show.
  private cachedTopology: FixtureTopology | null = null;
  private cachedFixtures: MusicFixtureDescriptor[] = [];
  private cachedTargets: MusicSpatialTarget[] = [];
  private cachedEnvelopeKeys: string[] = [];
  private cachedRoles = new Set<FixtureRole>();
  private cachedPaletteHex: number[] = [];
  private cachedPalette: HSB[] = [];

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
    this.paletteHoldsBeats = false;
    this.tiers.reset();
    this.lastClockBeatInBar = null;
    this.cachedTopology = null;
    this.cachedFixtures = [];
    this.cachedTargets = [];
    this.cachedEnvelopeKeys = [];
    this.cachedRoles.clear();
    this.cachedPaletteHex = [];
    this.cachedPalette = [];
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
    const targets = this.expandedTargets(topology, fixtures);
    if (targets.length === 0) {
      return { states: [], timestamp, sequenceNumber, sustainedEnergyEvent: false, flashApplied: false };
    }

    const dt = Math.max(1 / 120, Math.min(0.25, timestamp - (this.lastTimestamp ?? timestamp - 1 / 30)));
    this.lastTimestamp = timestamp;
    // The tier needs this frame's bar position, and the clock needs the tier
    // (it sets the attack the prediction compensates for, and half-time).
    // Measure on the plain clock, then build the one the show renders.
    const plainClock = this.musicalClock(snapshot, timestamp, config, MusicChoreographyEngine.attackTime, false);
    const tier = this.tiers.update(snapshot.energy, dt, plainClock.barPosition, plainClock.strength, snapshot.barEnergy);
    const attackTime = TIER_ATTACK[tier];
    // Calm music on a fast grid nods on every other beat, the way a listener
    // would. Only when the user left time feel on Auto and the grid itself
    // reads straight; an explicit feel always wins.
    const autoHalfTime = config.timeFeel === "auto" && snapshot.timeFeel === "straight" &&
      tier <= 2 && plainClock.interval > 0 && plainClock.interval < 0.5;
    const clock = this.musicalClock(snapshot, timestamp, config, attackTime, autoHalfTime);
    const enteredDownbeat = clock.strength >= 0.5 && clock.beatInBar === 0 &&
      this.lastClockBeatInBar != null && this.lastClockBeatInBar !== 0;
    this.lastClockBeatInBar = clock.strength >= 0.5 ? clock.beatInBar : null;

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

    this.advancePalette(newBeats, clock, config, dt, tier >= 4 && !reducedMotion);
    this.advanceMovement(clock, config, dt);

    const beganSustained = this.updateSustainedEnergy(this.fastEnergy, timestamp);
    const percussionRequest = Math.max(
      snapshot.snare * config.percussionSensitivity,
      snapshot.percussion * config.percussionSensitivity * 0.9,
    );
    // The top tier may ask for a flash on the downbeat. Like every other
    // request it goes through the limiter, which No-flash mode closes.
    const requestedFlash = Math.max(
      percussionRequest > 0.62 ? percussionRequest : 0,
      beganSustained ? 0.8 : 0,
      tier === 5 && enteredDownbeat ? 0.85 : 0,
    );
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
      (0.12 + 0.88 * dynamicsGate) *
      TIER_DEPTH[tier];

    const lowerBrightness = config.minimumBrightness * config.masterBrightness;
    const upperBrightness = config.maximumBrightness * config.masterBrightness;
    const palette = this.convertedPalette(config.palette);
    const phraseLift = config.phraseAware ? Math.min(0.18, energyRise * 0.9) : 0;

    // A room of two or three bulbs cannot show travel, so a sweep there is one
    // more brightness wobble. Spend movement on colour position instead; a
    // segmented fixture gets the full spatial treatment.
    const resolution = targets.length;
    const spatialFidelity = resolution >= 8 ? 1 : resolution >= 4 ? 0.6 : 0.3;
    const motionDepth = config.movementAmount * spatialFidelity;

    // These values depend on the frame or role, never on the segment. In a
    // long strip this replaces hundreds of repeated exponentials and powers.
    const bassBed = snapshot.bass * config.bassSensitivity * 0.1;
    const sustainedLift = config.phraseAware && this.sustainedEnergyEvent ? 0.06 + this.fastEnergy * 0.08 : 0;
    const commonBed = 0.1 + Math.pow(clamp01(this.dynamics), 0.7) * 0.4 + bassBed + phraseLift + sustainedLift;
    const effectScale = 0.6 + config.effectIntensity * 0.5;
    const hitDepth = this.cachedRoles.has("hit") ? 1 - Math.exp(-Math.max(0, baseDepth * 1.7 + snapshot.kick * config.bassSensitivity * 0.1 * config.effectIntensity * config.beatSensitivity) * 1.6) : 0;
    const accentDepth = this.cachedRoles.has("accent") ? 1 - Math.exp(-Math.max(0, baseDepth * 0.6 + this.accentEnvelope * 0.18 * config.effectIntensity * config.beatSensitivity) * 1.6) : 0;
    const motionSwellDepth = this.cachedRoles.has("motion") ? 1 - Math.exp(-Math.max(0, baseDepth * 0.92) * 1.6) : 0;
    const washDepth = this.cachedRoles.has("wash") || this.cachedRoles.has("auto") ? 1 - Math.exp(-Math.max(0, baseDepth * 1.15) * 1.6) : 0;
    const p = clamp01(pulseDrive);
    const hitPulse = Math.min(1, p + 2 * Math.max(0, p - 0.35) * (1 - p));
    const attack = 1 - Math.exp(-dt / attackTime);
    // Release stays a fraction of the felt beat, relaxed in quiet passages.
    const musicalRelease = Math.min(0.45, Math.max(0.13, feltInterval * 0.26));
    const quietStretch = 1 + Math.max(0, 0.6 - clamp01(this.dynamics)) * 1.2;
    const releaseTime = silence ? 0.8 : musicalRelease * quietStretch;
    const release = 1 - Math.exp(-dt / releaseTime);
    const brightnessFloor = silence && config.silenceBehavior === "fadeOut" ? 0 : lowerBrightness;
    const spread = config.colorChangeIntensity * (0.35 + spatialFidelity * 0.65);
    const paletteSpan = Math.max(1, palette.length - 1);
    const paletteCount = Math.max(1, palette.length);
    const transitionDuration = silence ? 0.55 : flashIntensity > 0 ? 0.04 : 0.09;

    const states: MusicLightingState[] = [];
    for (let index = 0; index < targets.length; index += 1) {
      const target = targets[index];
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
      let bedLevel = commonBed;
      // A hit fixture rests darker so it has headroom to punch.
      if (isHit) bedLevel *= 0.76;
      else if (isAccent) bedLevel *= 0.85;
      bedLevel = clamp01(bedLevel * effectScale * spatialWeight);

      // The swell: an accent inside the headroom above the bed.
      const depth = isHit ? hitDepth : isWash ? washDepth : isMotion ? motionSwellDepth : accentDepth;
      const bed = lowerBrightness + (upperBrightness - lowerBrightness) * bedLevel;
      const rolePulse = isHit ? hitPulse : p;
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
        brightnessFloor,
        Math.min(upperBrightness, rawBrightness),
      );

      const envelopeKey = this.cachedEnvelopeKeys[index];
      const previous = this.brightnessEnvelopes.get(envelopeKey) ?? rawBrightness;
      const coefficient = rawBrightness > previous ? attack : release;
      let brightness = previous + (rawBrightness - previous) * coefficient;
      brightness += flashIntensity * Math.max(0, upperBrightness - brightness);
      brightness = Math.max(brightnessFloor, Math.min(upperBrightness, brightness));
      this.brightnessEnvelopes.set(envelopeKey, brightness);

      // A palette entry held for a whole number of bars and cross-faded over
      // one beat at the bar line, plus a spatial offset so the room reads as
      // one gradient.
      const paletteMotion =
        target.position * spread * paletteSpan + this.paletteProgress + (isAccent && palette.length > 1 ? 1 : 0);
      const color = paletteColor(palette, paletteMotion / paletteCount);
      if (flashIntensity > 0) color.saturation *= 1 - flashIntensity * 0.8;

      states.push({
        fixtureID: target.fixtureID,
        segmentID: target.segmentID,
        hue: color.hue,
        saturation: clamp01(color.saturation),
        brightness: clamp01(brightness),
        // The transition covers the gap to the next frame, so a fixture
        // interpolates between commands instead of stepping.
        transitionDuration,
        priority: flashIntensity > 0 ? 3 : isHit ? 2 : 1,
      });
    }

    return {
      states,
      timestamp,
      sequenceNumber,
      sustainedEnergyEvent: this.sustainedEnergyEvent,
      flashApplied: flashIntensity > 0,
      energyTier: tier,
    };
  }

  private expandedTargets(topology: FixtureTopology, fixtures: MusicFixtureDescriptor[]): MusicSpatialTarget[] {
    const previous = this.cachedTopology;
    if (!previous || previous.layout !== topology.layout ||
        !sameStrings(previous.fixtureOrder, topology.fixtureOrder) ||
        !sameStrings(previous.excludedFixtureIDs, topology.excludedFixtureIDs) ||
        !sameFixtures(this.cachedFixtures, fixtures)) {
      this.cachedTopology = {
        layout: topology.layout,
        fixtureOrder: [...topology.fixtureOrder],
        excludedFixtureIDs: [...topology.excludedFixtureIDs],
      };
      this.cachedFixtures = fixtures.map(fixture => ({ ...fixture }));
      this.cachedTargets = expandedTargets(topology, fixtures);
      this.cachedEnvelopeKeys = this.cachedTargets.map(target => `${target.fixtureID}#${target.segmentID ?? -1}`);
      this.cachedRoles = new Set(this.cachedTargets.map(target => target.role));
    }
    return this.cachedTargets;
  }

  private convertedPalette(colors: MusicPaletteColor[]): HSB[] {
    if (colors.length !== this.cachedPaletteHex.length ||
        colors.some((color, index) => color.hex !== this.cachedPaletteHex[index])) {
      this.cachedPaletteHex = colors.map(color => color.hex);
      this.cachedPalette = colors.map(toHsb);
    }
    return this.cachedPalette;
  }

  private musicalClock(
    snapshot: AudioReactiveSnapshot,
    timestamp: number,
    config: MusicModeConfiguration,
    attackTime: number,
    halfTime: boolean,
  ): MusicalClock {
    const felt = snapshot.feltInterval > 0 ? snapshot.feltInterval : snapshot.beatInterval;
    const interval = halfTime ? felt * 2 : felt;
    const metre = snapshot.metre || 4;
    const blank: MusicalClock = {
      beatPosition: 0, phase: 0, beatInBar: 0, interval: 0, strength: 0, barRate: 0, metre, barPosition: 0,
    };
    if (!snapshot.isTempoLocked || interval <= 0 || snapshot.beatReferenceTime <= 0) return blank;
    if (timestamp - snapshot.beatReferenceTime >= interval * 6) return blank;

    // Compensate for transport, firmware delay, and the envelope's own rise
    // time, or the swell lands consistently late.
    // The user's light timing offset adds to the fixed estimate.
    const predicted =
      timestamp + MusicChoreographyEngine.outputLatency + (config.outputLatencyOffset ?? 0) + attackTime * 0.8;
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
      beatPosition: beats,
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
      // `beatCount` also advances on the analyzer's fallback onset detections
      // before a tempo locks, so its modulo is not aligned with `beatInBar`,
      // which is the authoritative position in the bar. Counting bars from
      // (count - beatInBar) steps exactly on the downbeat.
      barPosition:
        Math.floor((snapshot.beatCount - snapshot.beatInBar) / metre) +
        (snapshot.beatInBar + gridBeats) / metre,
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
  private advancePalette(
    _newBeats: number,
    clock: MusicalClock,
    configuration: MusicModeConfiguration,
    dt: number,
    stepsPerBeat: boolean,
  ): void {
    if (configuration.colorChangeIntensity <= 0) { this.lastPaletteHold = null; return; }
    if (clock.strength > 0 && clock.barRate > 0) {
      // High tiers step colour on the beat (every other beat above 180 BPM,
      // so colour never changes more than three times a second) and fade over
      // a quarter beat. Lower tiers hold whole bars and fade over one beat.
      const beatsPerStep = Math.max(1, Math.ceil(1 / (3 * clock.interval)));
      const hold = stepsPerBeat
        ? Math.floor(clock.beatPosition / beatsPerStep)
        : Math.floor(clock.barPosition / Math.max(1, Math.round(5 - configuration.colorChangeIntensity * 4)));
      // A change of hold unit adopts the current colour, like reacquisition.
      if (this.lastPaletteHold != null && stepsPerBeat !== this.paletteHoldsBeats) this.lastPaletteHold = null;
      this.paletteHoldsBeats = stepsPerBeat;
      const where = stepsPerBeat ? clock.beatPosition : clock.barPosition;
      if (this.lastPaletteHold != null && hold !== this.lastPaletteHold) {
        this.paletteFadeFrom = this.paletteProgress; this.paletteFadeTo = this.paletteProgress + 1; this.paletteFadeBar = where;
      } else if (this.lastPaletteHold == null) {
        this.paletteFadeFrom = this.paletteFadeTo = this.paletteProgress; this.paletteFadeBar = where;
      }
      this.lastPaletteHold = hold;
      const blend = stepsPerBeat
        ? clamp01((where - this.paletteFadeBar) * 4)
        : clamp01((where - this.paletteFadeBar) * clock.metre);
      this.paletteProgress = this.paletteFadeFrom + (this.paletteFadeTo - this.paletteFadeFrom) * blend;
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

function sameStrings(a: string[], b: string[]): boolean {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1) if (a[index] !== b[index]) return false;
  return true;
}

function sameFixtures(a: MusicFixtureDescriptor[], b: MusicFixtureDescriptor[]): boolean {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index += 1) {
    const previous = a[index], fixture = b[index];
    if (previous.id !== fixture.id || previous.label !== fixture.label ||
        previous.transport !== fixture.transport || previous.segmentCount !== fixture.segmentCount ||
        previous.role !== fixture.role) return false;
  }
  return true;
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
