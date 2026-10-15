import Foundation

/// Enforces the final, non-bypassable flash policy after all musical mappings
/// have requested accents. No audio event can directly create a flash.
struct FlashSafetyLimiter {
    static let hardMaximumFrequency: Double = 3

    private(set) var lastFlashTimestamp: TimeInterval?

    mutating func admit(
        at timestamp: TimeInterval,
        requestedIntensity: Double,
        configuration: MusicModeConfiguration
    ) -> Double {
        let config = configuration
        guard !config.photosensitivitySafeMode,
              config.allowsFlashes,
              config.flashIntensity > 0,
              config.maximumFlashFrequency > 0,
              requestedIntensity > 0 else { return 0 }

        let frequency = min(Self.hardMaximumFrequency, config.maximumFlashFrequency)
        let minimumInterval = 1 / frequency
        if let lastFlashTimestamp,
           timestamp - lastFlashTimestamp + 0.000_001 < minimumInterval {
            return 0
        }
        lastFlashTimestamp = timestamp
        return min(1, requestedIntensity) * config.flashIntensity.clamped01
    }

    mutating func reset() {
        lastFlashTimestamp = nil
    }
}

/// Six energy gears, 0…5, with hysteresis so a bar sitting on a boundary
/// does not flip the show back and forth. A beat map supplies the current
/// bar's energy before it plays; live input can only report the bar just
/// finished, so live tiers lag by one bar. Without a grid, a two-second
/// energy average stands in for the bar.
///
/// Kept in lockstep with `EnergyTierTracker` in `web/app/src/music/choreography.ts`.
struct EnergyTierTracker {
    /// Depth of the beat swell in each tier. Tier 3 is the engine's original depth.
    static let depth: [Double] = [0.62, 0.74, 0.87, 1, 1.08, 1.15]
    /// Rise time per tier: calm music eases into a swell, loud music snaps.
    static let attack: [TimeInterval] = [0.14, 0.14, 0.07, 0.026, 0.026, 0.026]

    private var tierValue = -1
    private var barIndex: Int?
    private var barSum = 0.0
    private var barTime = 0.0
    private var longEnergy = 0.0
    private var freeEnergy = 0.0
    private var primed = false

    /// The current tier; 3 until the first measurement, which is the engine's original behaviour.
    var tier: Int { tierValue < 0 ? 3 : tierValue }

    @discardableResult
    mutating func update(energy: Double, dt: Double, barPosition: Double, gridStrength: Double,
                         mappedBarEnergy: Double? = nil) -> Int {
        if !primed { longEnergy = energy; freeEnergy = energy; primed = true }
        longEnergy = Self.follow(longEnergy, toward: energy, dt: dt, timeConstant: 20)
        if let mappedBarEnergy, mappedBarEnergy.isFinite {
            barIndex = nil
            applyTarget(max(0, min(1, mappedBarEnergy)))
            return tier
        }
        if gridStrength > 0, barPosition.isFinite {
            let bar = Int(floor(barPosition))
            if let current = barIndex {
                if bar != current {
                    if barTime >= 0.2 { applyTarget(liveTarget(barSum / barTime)) }
                    barIndex = bar; barSum = 0; barTime = 0
                }
            } else {
                barIndex = bar; barSum = 0; barTime = 0
            }
            barSum += energy * dt
            barTime += dt
            return tier
        }
        barIndex = nil
        freeEnergy = Self.follow(freeEnergy, toward: energy, dt: dt, timeConstant: 2)
        applyTarget(liveTarget(freeEnergy))
        return tier
    }

    mutating func reset() { self = EnergyTierTracker() }

    /// Same 60/40 absolute/relative split a beat map uses for its bars.
    private func liveTarget(_ mean: Double) -> Double {
        let absolute = max(0, min(1, mean / 0.75))
        let relative = max(0, min(1, 0.5 + (mean - longEnergy) / 0.25))
        return max(0, min(1, 0.6 * absolute + 0.4 * relative))
    }

    private mutating func applyTarget(_ target: Double) {
        let x = target * 5
        if tierValue < 0 { tierValue = max(0, min(5, Int(x.rounded()))); return }
        while tierValue < 5, x >= Double(tierValue) + 0.65 { tierValue += 1 }
        while tierValue > 0, x < Double(tierValue) - 0.65 { tierValue -= 1 }
    }

    private static func follow(_ current: Double, toward target: Double, dt: Double, timeConstant: Double) -> Double {
        guard timeConstant > 0 else { return target }
        return current + (target - current) * (1 - exp(-dt / timeConstant))
    }
}

/// Pure, vendor-neutral music-to-light mapping. State is limited to musical
/// envelopes, hysteresis, palette progression, and the flash safety gate.
///
/// Brightness is a **bed plus a swell**. The bed is where a fixture rests, and
/// it tracks the music's loudness over about half a second, so it carries
/// dynamics. The swell is an accent that occupies part of the headroom between
/// the bed and the ceiling, and it carries rhythm. Because a fixture falls back
/// to the bed rather than to the floor, a beat reads as an accent on a lit room
/// instead of the room going dark and coming back — which is the difference
/// between a groove and a strobe at the same rate.
///
/// The engine choreographs against musical time, not wall-clock time. When
/// `AudioReactiveSnapshot` carries a locked tempo, swells are shaped by the
/// position inside the felt beat, sweeps traverse the room over bars, and the
/// palette is held for a whole number of bars and cross-faded on the bar line.
///
/// Material with no detectable pulse — ambient, spoken word, sparse acoustic —
/// keeps a smoothed, energy-driven behavior. `MusicalClock.strength` cross-fades
/// between the two, and because it now reads a confidence that reflects how far
/// ahead of its rivals the tempo estimate actually is, an ambiguous grid renders
/// the smooth show rather than a confident wrong one.
final class MusicChoreographyEngine {
    /// Unmeasured legacy prediction bias, NOT a measured device latency.
    /// Capture, dispatch, firmware and visible response must be measured separately.
    private static let outputLatencyCompensation: TimeInterval = 0.045
    /// Rise time of the brightness envelope. A swell that begins on the beat
    /// peaks after it, so the clock compensates for this as well as for
    /// transport.
    private static let attackTime: TimeInterval = 0.026
    /// The bed is the dynamics line. It should move over phrases, not frames.
    private static let bedTimeConstant: TimeInterval = 0.55
    /// Fall time of the off-grid onset envelope. Bounded so that dense
    /// transients raise a level instead of firing a burst of pulses.
    private static let offGridRelease: TimeInterval = 0.28

    private var lastBeatCount = 0
    private var paletteProgress: Double = 0
    private var movementPhase: Double = 0
    private var highEnergyBeganAt: TimeInterval?
    private var sustainedEnergyEvent = false
    private var lastTimestamp: TimeInterval?
    private var brightnessEnvelopes: [String: Double] = [:]
    private var flashLimiter = FlashSafetyLimiter()

    // Musical state carried between frames.
    private var dynamics: Double = 0
    private var fastEnergy: Double = 0
    private var slowEnergy: Double = 0
    private var onsetEnvelope: Double = 0
    private var accentEnvelope: Double = 0
    private var lastPaletteHold: Int?
    private var paletteFadeFrom: Double = 0
    private var paletteFadeTo: Double = 0
    private var paletteFadeBar: Double = 0
    /// Whether the palette is currently stepping per beat (high tiers) or per bar.
    private var paletteHoldsBeats = false
    private var tiers = EnergyTierTracker()
    private var lastClockBeatInBar: Int?

    // Topology expansion includes fixture sorting, role resolution, and one
    // target allocation per segment. Palette conversion is also independent
    // of the audio frame. Reuse both until their complete inputs change.
    private var cachedTopology: FixtureTopology?
    private var cachedFixtures: [MusicFixtureDescriptor] = []
    private var cachedTargets: [MusicSpatialTarget] = []
    private var cachedEnvelopeKeys: [String] = []
    private var hasHitTargets = false
    private var hasAccentTargets = false
    private var hasMotionTargets = false
    private var hasWashTargets = false
    private var cachedPaletteColors: [MusicPaletteColor] = []
    private var cachedPalette: [HSB] = []

    func reset() {
        lastBeatCount = 0
        paletteProgress = 0
        movementPhase = 0
        highEnergyBeganAt = nil
        sustainedEnergyEvent = false
        lastTimestamp = nil
        brightnessEnvelopes.removeAll(keepingCapacity: true)
        flashLimiter.reset()
        dynamics = 0
        fastEnergy = 0
        slowEnergy = 0
        onsetEnvelope = 0
        accentEnvelope = 0
        lastPaletteHold = nil
        paletteFadeFrom = 0; paletteFadeTo = 0; paletteFadeBar = 0
        paletteHoldsBeats = false
        tiers.reset()
        lastClockBeatInBar = nil
        cachedTopology = nil
        cachedFixtures.removeAll(keepingCapacity: true)
        cachedTargets.removeAll(keepingCapacity: true)
        cachedEnvelopeKeys.removeAll(keepingCapacity: true)
        hasHitTargets = false
        hasAccentTargets = false
        hasMotionTargets = false
        hasWashTargets = false
        cachedPaletteColors.removeAll(keepingCapacity: true)
        cachedPalette.removeAll(keepingCapacity: true)
    }

    func makeFrame(
        snapshot input: AudioReactiveSnapshot,
        configuration: MusicModeConfiguration,
        topology: FixtureTopology,
        fixtures: [MusicFixtureDescriptor],
        timestamp: TimeInterval,
        sequenceNumber: UInt64,
        reducedMotion: Bool = false
    ) -> MusicLightingFrame {
        let snapshot = input.fresh(at: timestamp)
        let config = configuration.normalized(reducedMotion: reducedMotion)
        let targets = expandedTargets(for: topology, fixtures: fixtures)
        guard !targets.isEmpty else {
            return MusicLightingFrame(
                states: [], timestamp: timestamp, sequenceNumber: sequenceNumber,
                sustainedEnergyEvent: false, flashApplied: false
            )
        }

        let dt = max(1 / 120, min(0.25, timestamp - (lastTimestamp ?? timestamp - 1 / 30)))
        lastTimestamp = timestamp
        // The tier needs this frame's bar position, and the clock needs the
        // tier (it sets the attack the prediction compensates for, and
        // half-time). Measure on the plain clock, then build the one the show renders.
        let plainClock = musicalClock(snapshot: snapshot, timestamp: timestamp, configuration: config,
                                      attackTime: Self.attackTime, halfTime: false)
        let tier = tiers.update(energy: snapshot.energy, dt: dt, barPosition: plainClock.barPosition,
                                gridStrength: plainClock.strength, mappedBarEnergy: snapshot.barEnergy)
        let attackTime = EnergyTierTracker.attack[tier]
        // Calm music on a fast grid nods on every other beat, the way a
        // listener would. Only when time feel is left on Auto and the grid
        // itself reads straight; an explicit feel always wins.
        let autoHalfTime = config.timeFeel == .auto && snapshot.timeFeel == .straight
            && tier <= 2 && plainClock.interval > 0 && plainClock.interval < 0.5
        let clock = musicalClock(snapshot: snapshot, timestamp: timestamp, configuration: config,
                                 attackTime: attackTime, halfTime: autoHalfTime)
        let enteredDownbeat = clock.strength >= 0.5 && clock.beatInBar == 0
            && lastClockBeatInBar != nil && lastClockBeatInBar != 0
        lastClockBeatInBar = clock.strength >= 0.5 ? clock.beatInBar : nil

        let newBeats = snapshot.beatCount > lastBeatCount ? snapshot.beatCount - lastBeatCount : 0
        lastBeatCount = snapshot.beatCount

        let silence = snapshot.confidence < 0.025 && snapshot.level < 0.025 && snapshot.energy < 0.035

        // One loudness line, smoothed over about half a second. Everything that
        // used to read a raw per-frame level or energy reads this instead, so a
        // single noisy analysis hop cannot move the room.
        let loudness = max(snapshot.level, snapshot.energy)
        dynamics = Self.follow(dynamics, toward: loudness, dt: dt,
                               timeConstant: silence ? 0.9 : Self.bedTimeConstant)
        // A long/short energy pair. Their difference is a phrase building,
        // where the single-hop energy difference this replaces was measurement
        // noise worth up to a fifth of a fixture's drive.
        fastEnergy = Self.follow(fastEnergy, toward: snapshot.energy, dt: dt, timeConstant: 0.7)
        slowEnergy = Self.follow(slowEnergy, toward: snapshot.energy, dt: dt, timeConstant: 5)
        let energyRise = max(0, fastEnergy - slowEnergy)

        advancePalette(newBeats: newBeats, clock: clock, configuration: config, dt: dt,
                       stepsPerBeat: tier >= 4 && !reducedMotion)
        advanceMovement(clock: clock, configuration: config, dt: dt)

        let beganSustainedEvent = updateSustainedEnergy(fastEnergy, at: timestamp)
        let percussionRequest = max(
            snapshot.snare * config.percussionSensitivity,
            snapshot.percussion * config.percussionSensitivity * 0.9
        )
        // The top tier may ask for a flash on the downbeat. Like every other
        // request it goes through the limiter, which No-flash mode closes.
        let requestedFlash = max(percussionRequest > 0.62 ? percussionRequest : 0,
                                 beganSustainedEvent ? 0.8 : 0,
                                 tier == 5 && enteredDownbeat ? 0.85 : 0)
        let flashIntensity = flashLimiter.admit(
            at: timestamp,
            requestedIntensity: requestedFlash,
            configuration: config
        )

        // On the grid a pulse is a contour across the felt beat, weighted by
        // where the beat sits in the bar. Off the grid it is a smoothed onset
        // envelope with a bounded fall, so a wall of hi-hats raises a level
        // rather than retriggering a pulse several times a second.
        onsetEnvelope = max(onsetEnvelope * exp(-dt / Self.offGridRelease),
                            max(snapshot.beat, snapshot.pulse))
        let musicalPulse = Self.beatShape(phase: clock.phase)
            * Self.barAccent(clock.beatInBar, metre: clock.metre)
        let pulseDrive = onsetEnvelope + (musicalPulse - onsetEnvelope) * clock.strength

        // Percussion accent as a decaying envelope rather than a threshold
        // toggle, so an accent fixture fades instead of switching.
        let accentTarget = (snapshot.snare * config.percussionSensitivity).clamped01
        accentEnvelope = max(accentEnvelope * exp(-dt / 0.35), accentTarget)

        // How deep a beat is allowed to dig, as a fraction of the headroom
        // above the bed. It rises with sensitivity and with the music's own
        // loudness, and it shrinks at fast tempos so the rate of *visible*
        // musical events stays musical however fast analysis and frame
        // delivery run.
        let feltInterval = clock.interval > 0 ? clock.interval : 0.5
        let tempoRestraint = ((feltInterval - 0.22) / 0.26).clamped01
        let dynamicsGate = pow(dynamics.clamped01, 1.5)
        let baseDepth = config.beatSensitivity * 1.57
            * (0.6 + config.effectIntensity * 0.4) * min(1, config.effectIntensity / 0.2)
            * (0.4 + 0.6 * tempoRestraint)
            * (0.12 + 0.88 * dynamicsGate)
            * EnergyTierTracker.depth[tier]

        // Master scales both bounds. Final output is clamped AFTER envelopes/flash.
        let lowerBrightness = config.minimumBrightness * config.masterBrightness
        let upperBrightness = config.maximumBrightness * config.masterBrightness
        let palette = convertedPalette(for: config.palette)
        let phraseLift = config.phraseAware ? min(0.18, energyRise * 0.9) : 0

        // A room of two or three bulbs cannot show travel, so a sweep there is
        // only one more brightness wobble stacked on the beat. Spend movement
        // on colour position instead and keep the brightness tilt shallow; a
        // segmented fixture gets the full spatial treatment because it can
        // actually render it.
        let resolution = targets.count
        let spatialFidelity: Double = resolution >= 8 ? 1 : (resolution >= 4 ? 0.6 : 0.3)
        let motionDepth = config.movementAmount * spatialFidelity

        // Frame- and role-wide terms are independent of segment placement.
        // Compute powers and envelope coefficients once even for long strips.
        let bassBed = snapshot.bass * config.bassSensitivity * 0.1
        let sustainedLift = config.phraseAware && sustainedEnergyEvent ? 0.06 + fastEnergy * 0.08 : 0
        let commonBed = 0.1 + pow(dynamics.clamped01, 0.7) * 0.4 + bassBed + phraseLift + sustainedLift
        let effectScale = 0.6 + config.effectIntensity * 0.5
        let hitDepth = hasHitTargets ? 1 - exp(-max(0, baseDepth * 1.7
            + snapshot.kick * config.bassSensitivity * 0.1 * config.effectIntensity * config.beatSensitivity) * 1.6) : 0
        let accentDepth = hasAccentTargets ? 1 - exp(-max(0, baseDepth * 0.6
            + accentEnvelope * 0.18 * config.effectIntensity * config.beatSensitivity) * 1.6) : 0
        let motionSwellDepth = hasMotionTargets ? 1 - exp(-max(0, baseDepth * 0.92) * 1.6) : 0
        let washDepth = hasWashTargets ? 1 - exp(-max(0, baseDepth * 1.15) * 1.6) : 0
        let p = pulseDrive.clamped01
        // Broaden only the crest for hit fixtures, preserving half-time gaps.
        let hitPulse = min(1, p + 2 * max(0, p - 0.35) * (1 - p))
        let attack = 1 - exp(-dt / attackTime)
        // Release stays a fraction of the felt beat, relaxed in quiet passages.
        let musicalRelease = min(0.45, max(0.13, feltInterval * 0.26))
        let quietStretch = 1 + max(0, 0.6 - dynamics.clamped01) * 1.2
        let releaseTime = silence ? 0.8 : musicalRelease * quietStretch
        let release = 1 - exp(-dt / releaseTime)
        let brightnessFloor = silence && config.silenceBehavior == .fadeOut ? 0 : lowerBrightness
        let spread = config.colorChangeIntensity * (0.35 + spatialFidelity * 0.65)
        let paletteSpan = Double(max(1, palette.count - 1))
        let paletteCount = Double(max(1, palette.count))
        let transitionDuration = silence ? 0.55 : (flashIntensity > 0 ? 0.04 : 0.09)

        var states: [MusicLightingState] = []
        states.reserveCapacity(targets.count)
        for (index, target) in targets.enumerated() {
            let isHit = target.role == .hit
            let isAccent = target.role == .accent
            let isMotion = target.role == .motion
            let isWash = target.role == .wash || target.role == .auto

            // A full turn at the two endpoints made two bulbs move identically.
            let spatialPosition = topology.layout == .circular ? target.position : target.position * 0.75
            let phase = spatialPhase(position: spatialPosition, direction: config.movementDirection)
            let wave = 0.5 + 0.5 * sin(phase * 2 * .pi)
            let stereoBias = 1 + (snapshot.stereo - 0.5) * 2 * config.stereoImage * (target.position - 0.5) * 2
            // Centred on 1 so movement tilts the room rather than dimming it.
            let spatialWeight = (1 - motionDepth * 0.5 + motionDepth * wave)
                * max(0.6, min(1.4, stereoBias))

            // The bed: where this fixture rests between accents.
            var bedLevel = commonBed
            // A hit fixture rests darker so it has headroom to punch; a wash
            // sits in the room and only lifts.
            if isHit { bedLevel *= 0.76 } else if isAccent { bedLevel *= 0.85 }
            bedLevel = (bedLevel * effectScale * spatialWeight).clamped01

            // The swell: an accent inside the headroom above the bed.
            let depth = isHit ? hitDepth : (isWash ? washDepth : (isMotion ? motionSwellDepth : accentDepth))
            let bed = lowerBrightness + (upperBrightness - lowerBrightness) * bedLevel
            let rolePulse = isHit ? hitPulse : p
            var rawBrightness = bed + (upperBrightness - bed) * depth * rolePulse

            if silence {
                switch config.silenceBehavior {
                case .settle:
                    rawBrightness = lowerBrightness
                case .holdPalette:
                    rawBrightness = lowerBrightness
                        + (upperBrightness - lowerBrightness) * (0.08 + config.effectIntensity * 0.08)
                case .fadeOut:
                    rawBrightness = 0
                }
            }
            rawBrightness = max(
                brightnessFloor,
                min(upperBrightness, rawBrightness)
            )

            let envelopeKey = cachedEnvelopeKeys[index]
            let previous = brightnessEnvelopes[envelopeKey] ?? rawBrightness
            let coefficient = rawBrightness > previous ? attack : release
            var brightness = previous + (rawBrightness - previous) * coefficient
            brightness += flashIntensity * max(0, upperBrightness - brightness)
            brightness = max(brightnessFloor,
                             min(upperBrightness, brightness))
            brightnessEnvelopes[envelopeKey] = brightness

            // Colour: a palette entry held for a whole number of bars and
            // cross-faded over one beat at the bar line, plus a spatial offset
            // so the room reads as one gradient. `paletteColor` takes a 0…1
            // position across the whole palette, so entries are converted at
            // the last moment.
            let paletteMotion = target.position * spread * paletteSpan
                + paletteProgress + (isAccent && palette.count > 1 ? 1 : 0)
            var color = Self.paletteColor(palette, position: paletteMotion / paletteCount)

            if flashIntensity > 0 {
                color.saturation *= 1 - flashIntensity * 0.8
            }

            states.append(MusicLightingState(
                fixtureID: target.fixtureID,
                segmentID: target.segmentID,
                hue: color.hue,
                saturation: color.saturation.clamped01,
                brightness: brightness.clamped01,
                // The transition covers the gap to the next frame, so a fixture
                // interpolates between commands instead of stepping.
                transitionDuration: transitionDuration,
                priority: flashIntensity > 0 ? 3 : (isHit ? 2 : 1)
            ))
        }

        return MusicLightingFrame(
            states: states,
            timestamp: timestamp,
            sequenceNumber: sequenceNumber,
            sustainedEnergyEvent: sustainedEnergyEvent,
            flashApplied: flashIntensity > 0,
            energyTier: tier
        )
    }

    private func expandedTargets(
        for topology: FixtureTopology,
        fixtures: [MusicFixtureDescriptor]
    ) -> [MusicSpatialTarget] {
        if cachedTopology != topology || cachedFixtures != fixtures {
            cachedTopology = topology
            cachedFixtures = fixtures
            cachedTargets = topology.expandedTargets(for: fixtures)
            cachedEnvelopeKeys = cachedTargets.map { "\($0.fixtureID)#\($0.segmentID ?? -1)" }
            hasHitTargets = cachedTargets.contains { $0.role == .hit }
            hasAccentTargets = cachedTargets.contains { $0.role == .accent }
            hasMotionTargets = cachedTargets.contains { $0.role == .motion }
            hasWashTargets = cachedTargets.contains { $0.role == .wash || $0.role == .auto }
        }
        return cachedTargets
    }

    private func convertedPalette(for colors: [MusicPaletteColor]) -> [HSB] {
        if cachedPaletteColors != colors {
            cachedPaletteColors = colors
            cachedPalette = colors.map(Self.hsb)
        }
        return cachedPalette
    }

    /// One-pole follower toward `target` over `timeConstant` seconds.
    private static func follow(
        _ current: Double,
        toward target: Double,
        dt: Double,
        timeConstant: Double
    ) -> Double {
        guard timeConstant > 0 else { return target }
        return current + (target - current) * (1 - exp(-dt / timeConstant))
    }

    private func updateSustainedEnergy(_ energy: Double, at timestamp: TimeInterval) -> Bool {
        var began = false
        if sustainedEnergyEvent {
            if energy < 0.5 {
                sustainedEnergyEvent = false
                highEnergyBeganAt = nil
            }
        } else if energy > 0.7 {
            if highEnergyBeganAt == nil { highEnergyBeganAt = timestamp }
            if timestamp - (highEnergyBeganAt ?? timestamp) >= 0.8 {
                sustainedEnergyEvent = true
                began = true
            }
        } else if energy < 0.62 {
            highEnergyBeganAt = nil
        }
        return began
    }

    private func spatialPhase(position: Double, direction: MusicMovementDirection) -> Double {
        let time = movementPhase
        switch direction {
        case .forward, .clockwise, .alternating: return position - time
        case .reverse, .counterclockwise: return position + time
        case .expanding: return abs(position - 0.5) * 2 - time
        case .contracting: return abs(position - 0.5) * 2 + time
        }
    }

    // MARK: - Musical time

    /// Where the frame being rendered sits in the music. Internal so tests
    /// can check the prediction directly.
    struct MusicalClock {
        /// Absolute position in felt beats; its whole part counts beats.
        var beatPosition: Double = 0
        /// 0…1 position inside the current felt beat, 0 exactly on the beat.
        var phase: Double = 0
        /// Which beat of the current bar this is.
        var beatInBar: Int = 0
        /// Seconds per felt beat, or 0 when there is no usable grid.
        var interval: TimeInterval = 0
        /// How far to trust the grid: 0 renders the energy-driven show, 1 the
        /// fully beat-synchronized one, and values between cross-fade.
        var strength: Double = 0
        /// Bars per second, 0 when there is no usable grid.
        var barRate: Double = 0
        var metre: Int = 4
        /// Absolute position in bars on the detected grid.
        var barPosition: Double = 0
    }

    func musicalClock(
        snapshot: AudioReactiveSnapshot,
        timestamp: TimeInterval,
        configuration: MusicModeConfiguration,
        attackTime: TimeInterval,
        halfTime: Bool
    ) -> MusicalClock {
        let felt = snapshot.feltInterval > 0 ? snapshot.feltInterval : snapshot.beatInterval
        let interval = halfTime ? felt * 2 : felt
        let metre = snapshot.metre > 0 ? snapshot.metre : BeatTracker.beatsPerBar
        guard snapshot.isTempoLocked,
              interval > 0,
              snapshot.beatReferenceTime > 0 else { return MusicalClock(metre: metre) }
        // A reference this old means analysis stopped feeding the grid (capture
        // ended, the audio went silent). Extrapolating from it would drift, so
        // fall back to the reactive show instead.
        guard timestamp - snapshot.beatReferenceTime < interval * 6 else { return MusicalClock(metre: metre) }

        // Evaluating slightly ahead is only meaningful on a predicted grid: it
        // pays for transport, firmware delay, and the envelope's own rise time,
        // so the swell lands on the beat rather than a frame or two behind it.
        // The user's light timing offset adds to the fixed estimate.
        let predicted = timestamp + Self.outputLatencyCompensation + configuration.outputLatencyOffset
            + attackTime * 0.8
        let gridInterval = snapshot.beatInterval > 0 ? snapshot.beatInterval : interval
        let gridBeats = (predicted - snapshot.beatReferenceTime) / gridInterval
        // The reference advances on every detected beat. Include its position
        // on the grid before dividing into felt beats, or half-time restarts
        // its pulse halfway through every cycle.
        let absoluteBeat = Double(snapshot.gridBeatPosition ?? snapshot.beatCount) + gridBeats
        let beats = absoluteBeat * gridInterval / interval
        let wholeBeats = floor(beats)
        let beatInBar = Int(((Double(snapshot.beatInBar) + floor(gridBeats))
            .truncatingRemainder(dividingBy: Double(metre))
            + Double(metre))
            .truncatingRemainder(dividingBy: Double(metre)))
        return MusicalClock(
            beatPosition: beats,
            phase: beats - wholeBeats,
            beatInBar: beatInBar,
            interval: interval,
            // Confidence now reflects how far the tempo estimate is ahead of
            // its nearest rival period rather than how far it is above the
            // average of every lag, so this cross-fade does real work: an
            // ambiguous grid renders the smooth energy-driven show instead of
            // a confident wrong one.
            strength: ((snapshot.beatConfidence - 0.25) / 0.45).clamped01,
            barRate: 1 / (gridInterval * Double(metre)),
            metre: metre,
            // `beatCount` also advances on the analyzer's fallback onset
            // detections before a tempo locks, so its modulo is not aligned
            // with `beatInBar`, which is the authoritative position in the bar.
            // Deriving the bar straight from the count therefore put the
            // palette boundary on an arbitrary beat. Counting bars from
            // (count - beatInBar) — constant inside a bar, and stepping by the
            // metre exactly on the downbeat — lands it on the downbeat instead.
            barPosition: (Double(snapshot.beatCount - snapshot.beatInBar) / Double(metre)).rounded(.down)
                + (Double(snapshot.beatInBar) + gridBeats) / Double(metre)
        )
    }

    /// Brightness contour across one felt beat: a short swell into the beat, a
    /// peak on it, then a decay across the rest. Unlike the curve this replaces
    /// it returns to a floor rather than to zero, so a beat is an accent on a
    /// lit room instead of the room going dark and coming back.
    private static func beatShape(phase: Double) -> Double {
        let decay = pow(max(0, 1 - phase), 2)
        let anticipation = phase > 0.86 ? pow((phase - 0.86) / 0.14, 2) * 0.62 : 0
        return 0.07 + 0.93 * max(decay, anticipation)
    }

    /// Relative weight of each beat in the current bar. The downbeat leads by a
    /// clear margin, so only the strong beats produce a large swing and the bar
    /// reads as a groove rather than as a metronome at full depth.
    private static func barAccent(_ beatInBar: Int, metre: Int) -> Double {
        if beatInBar == 0 { return 1 }
        switch metre {
        case 3: return beatInBar == 1 ? 0.46 : 0.6
        case 5: return beatInBar == 3 ? 0.72 : 0.46
        case 6: return beatInBar == 3 ? 0.72 : 0.48
        case 7: return beatInBar == 3 || beatInBar == 5 ? 0.7 : 0.46
        default:
            return beatInBar == 2 ? 0.72 : 0.5
        }
    }

    /// Palette progression measured in whole bars. On the grid an entry is held
    /// for an integer number of bars and cross-faded across one beat at the bar
    /// line, so the change lands on a downbeat by construction.
    ///
    /// Progression used to be a free-running accumulator quantized to *its own*
    /// integer boundaries. Entries-per-bar was not an integer, so a colour
    /// change landed at a different point in every bar and arrived about twice
    /// a second at the default setting.
    private func advancePalette(
        newBeats: Int,
        clock: MusicalClock,
        configuration: MusicModeConfiguration,
        dt: Double,
        stepsPerBeat: Bool
    ) {
        guard configuration.colorChangeIntensity > 0 else { lastPaletteHold = nil; return }
        if clock.strength > 0, clock.barRate > 0 {
            // High tiers step colour on the beat (every other beat above 180
            // BPM, so colour never changes more than three times a second) and
            // fade over a quarter beat. Lower tiers hold whole bars and fade
            // over one beat.
            let beatsPerStep: Double = clock.interval >= 1.0 / 3 ? 1 : 2
            let barsPerColour = Double(max(1, Int((5 - configuration.colorChangeIntensity * 4).rounded())))
            let hold = stepsPerBeat
                ? Int(floor(clock.beatPosition / beatsPerStep))
                : Int(floor(clock.barPosition / barsPerColour))
            // A change of hold unit adopts the current colour, like reacquisition.
            if lastPaletteHold != nil, stepsPerBeat != paletteHoldsBeats { lastPaletteHold = nil }
            paletteHoldsBeats = stepsPerBeat
            let place = stepsPerBeat ? clock.beatPosition : clock.barPosition
            if let previous = lastPaletteHold, hold != previous {
                paletteFadeFrom = paletteProgress
                paletteFadeTo = paletteProgress + 1
                paletteFadeBar = place
            } else if lastPaletteHold == nil {
                // Reacquisition adopts the current colour. Never map a new grid
                // count directly onto the palette and teleport across entries.
                paletteFadeFrom = paletteProgress; paletteFadeTo = paletteProgress
                paletteFadeBar = place
            }
            lastPaletteHold = hold
            let blend = stepsPerBeat
                ? ((place - paletteFadeBar) * 4).clamped01
                : ((place - paletteFadeBar) * Double(clock.metre)).clamped01
            paletteProgress = paletteFadeFrom + (paletteFadeTo - paletteFadeFrom) * blend
        } else {
            lastPaletteHold = nil
            paletteProgress += dt * configuration.colorChangeIntensity * 0.08
        }
    }

    /// Integrates the sweep rate rather than deriving an absolute phase from
    /// the clock, so gaining or losing tempo lock changes the speed of the
    /// motion without ever jumping its position.
    private func advanceMovement(clock: MusicalClock, configuration: MusicModeConfiguration, dt: Double) {
        guard configuration.movementSpeed > 0, configuration.movementAmount > 0 else { return }
        let wallClockRate = configuration.movementSpeed * 0.66
        var rate = wallClockRate
        if clock.strength > 0, clock.barRate > 0 {
            // One traverse every few bars at the default speed: motion that
            // reads as travel rather than as another oscillator stacked on
            // brightness.
            let traversesPerBar = 0.12 + configuration.movementSpeed * 0.55
            let musicalRate = traversesPerBar * clock.barRate
            rate = wallClockRate + (musicalRate - wallClockRate) * clock.strength
        }
        if configuration.movementDirection == .alternating {
            // Reverse on the bar line while locked. Without a grid there are no
            // bars, so fall back to flipping every four detected beats.
            let bar = clock.strength > 0 ? Int(floor(clock.barPosition)) : lastBeatCount / max(1, clock.metre)
            if !bar.isMultiple(of: 2) { rate = -rate }
        }
        movementPhase += rate * dt
    }

    private struct HSB {
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    private static func hsb(_ color: MusicPaletteColor) -> HSB {
        let rgb = color.rgb
        let maximum = max(rgb.red, max(rgb.green, rgb.blue))
        let minimum = min(rgb.red, min(rgb.green, rgb.blue))
        let delta = maximum - minimum
        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maximum == rgb.red {
            hue = ((rgb.green - rgb.blue) / delta / 6).wrappedUnit
        } else if maximum == rgb.green {
            hue = ((rgb.blue - rgb.red) / delta / 6 + 1 / 3).wrappedUnit
        } else {
            hue = ((rgb.red - rgb.green) / delta / 6 + 2 / 3).wrappedUnit
        }
        return HSB(
            hue: hue,
            saturation: maximum == 0 ? 0 : delta / maximum,
            brightness: maximum
        )
    }

    private static func paletteColor(_ palette: [HSB], position: Double) -> HSB {
        guard let first = palette.first else { return HSB(hue: 0, saturation: 0, brightness: 1) }
        guard palette.count > 1 else { return first }
        let wrapped = position.wrappedUnit * Double(palette.count)
        let low = Int(floor(wrapped)) % palette.count
        let high = (low + 1) % palette.count
        let fraction = wrapped - floor(wrapped)
        var hueDelta = palette[high].hue - palette[low].hue
        if hueDelta > 0.5 { hueDelta -= 1 }
        if hueDelta < -0.5 { hueDelta += 1 }
        // A near-white entry has no hue worth travelling to: its hue is
        // whatever rounding left behind. Interpolating toward it drags the
        // colour through hues the palette never contained, which showed up as
        // soon as the near-white catalog themes became selectable palettes.
        // Hold the chromatic end's hue instead and let saturation do the work.
        // Same threshold as `PaletteTone.blend` — one number, one meaning.
        let hue: Double
        if palette[low].saturation <= PaletteTone.achromaticSaturation {
            hue = palette[high].hue
        } else if palette[high].saturation <= PaletteTone.achromaticSaturation {
            hue = palette[low].hue
        } else {
            hue = (palette[low].hue + hueDelta * fraction).wrappedUnit
        }
        return HSB(
            hue: hue,
            saturation: palette[low].saturation + (palette[high].saturation - palette[low].saturation) * fraction,
            brightness: palette[low].brightness + (palette[high].brightness - palette[low].brightness) * fraction
        )
    }
}

private extension Double {
    var wrappedUnit: Double {
        let value = truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }

    /// `MusicMode.swift` has the same helper, but fileprivate to that file.
    var clamped01: Double { max(0, min(1, self)) }
}
