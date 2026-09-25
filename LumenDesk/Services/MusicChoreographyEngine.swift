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
        let config = configuration.normalized()
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
        return min(1, requestedIntensity) * config.flashIntensity
    }

    mutating func reset() {
        lastFlashTimestamp = nil
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
    private var barsElapsed: Double = 0
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

    func reset() {
        lastBeatCount = 0
        paletteProgress = 0
        movementPhase = 0
        barsElapsed = 0
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
        let targets = topology.expandedTargets(for: fixtures)
        guard !targets.isEmpty else {
            return MusicLightingFrame(
                states: [], timestamp: timestamp, sequenceNumber: sequenceNumber,
                sustainedEnergyEvent: false, flashApplied: false
            )
        }

        let dt = max(1 / 120, min(0.25, timestamp - (lastTimestamp ?? timestamp - 1 / 30)))
        lastTimestamp = timestamp
        let clock = musicalClock(snapshot: snapshot, timestamp: timestamp)

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

        advancePalette(newBeats: newBeats, clock: clock, configuration: config, dt: dt)
        advanceMovement(clock: clock, configuration: config, dt: dt)

        let beganSustainedEvent = updateSustainedEnergy(fastEnergy, at: timestamp)
        let percussionRequest = max(
            snapshot.snare * config.percussionSensitivity,
            snapshot.percussion * config.percussionSensitivity * 0.9
        )
        let requestedFlash = max(percussionRequest > 0.62 ? percussionRequest : 0,
                                 beganSustainedEvent ? 0.8 : 0)
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

        // Master scales both bounds. Final output is clamped AFTER envelopes/flash.
        let lowerBrightness = config.minimumBrightness * config.masterBrightness
        let upperBrightness = config.maximumBrightness * config.masterBrightness
        let palette = config.palette.map(Self.hsb)
        let phraseLift = config.phraseAware ? min(0.18, energyRise * 0.9) : 0

        // A room of two or three bulbs cannot show travel, so a sweep there is
        // only one more brightness wobble stacked on the beat. Spend movement
        // on colour position instead and keep the brightness tilt shallow; a
        // segmented fixture gets the full spatial treatment because it can
        // actually render it.
        let resolution = targets.count
        let spatialFidelity: Double = resolution >= 8 ? 1 : (resolution >= 4 ? 0.6 : 0.3)
        let motionDepth = config.movementAmount * spatialFidelity

        var states: [MusicLightingState] = []
        states.reserveCapacity(targets.count)
        for target in targets {
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
            let bassBed = snapshot.bass * config.bassSensitivity * 0.1
            let sustainedLift = config.phraseAware && sustainedEnergyEvent ? 0.06 + fastEnergy * 0.08 : 0
            var bedLevel = 0.1 + pow(dynamics.clamped01, 0.7) * 0.4 + bassBed + phraseLift + sustainedLift
            // A hit fixture rests darker so it has headroom to punch; a wash
            // sits in the room and only lifts.
            if isHit { bedLevel *= 0.76 } else if isAccent { bedLevel *= 0.85 }
            bedLevel = (bedLevel * (0.6 + config.effectIntensity * 0.5) * spatialWeight).clamped01

            // The swell: an accent inside the headroom above the bed.
            var depth = baseDepth
            if isHit { depth *= 1.7 }
            else if isWash { depth *= 1.15 }
            else if isMotion { depth *= 0.92 }
            else if isAccent { depth *= 0.6 }
            if isAccent { depth += accentEnvelope * 0.18 * config.effectIntensity * config.beatSensitivity }
            if isHit { depth += snapshot.kick * config.bassSensitivity * 0.1 * config.effectIntensity * config.beatSensitivity }
            // Soft-limit accent depth to leave headroom without flat-topping
            // every strong beat. The lit bed remains independent.
            depth = 1 - exp(-max(0, depth) * 1.6)

            let bed = lowerBrightness + (upperBrightness - lowerBrightness) * bedLevel
            // Broaden only the crest on Hit fixtures; lifting the whole contour
            // would fill in the intervening beat in half-time material.
            let p = pulseDrive.clamped01
            let rolePulse = isHit ? min(1, p + 2 * max(0, p - 0.35) * (1 - p)) : p
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
                silence && config.silenceBehavior == .fadeOut ? 0 : lowerBrightness,
                min(upperBrightness, rawBrightness)
            )

            let envelopeKey = "\(target.fixtureID)#\(target.segmentID ?? -1)"
            let previous = brightnessEnvelopes[envelopeKey] ?? rawBrightness
            let attack = 1 - exp(-dt / Self.attackTime)
            // Release is a fraction of the felt beat with a floor, so one
            // accent finishes before the next arrives at any tempo without ever
            // becoming a snap. The previous constant clamped to 60 ms for
            // anything at or above 120 BPM, which turned every beat into a
            // full-depth sawtooth. Quiet passages relax further still.
            let musicalRelease = min(0.45, max(0.13, feltInterval * 0.26))
            let quietStretch = 1 + max(0, 0.6 - dynamics.clamped01) * 1.2
            let releaseTime = silence ? 0.8 : musicalRelease * quietStretch
            let release = 1 - exp(-dt / releaseTime)
            let coefficient = rawBrightness > previous ? attack : release
            var brightness = previous + (rawBrightness - previous) * coefficient
            brightness += flashIntensity * max(0, upperBrightness - brightness)
            brightness = max(silence && config.silenceBehavior == .fadeOut ? 0 : lowerBrightness,
                             min(upperBrightness, brightness))
            brightnessEnvelopes[envelopeKey] = brightness

            // Colour: a palette entry held for a whole number of bars and
            // cross-faded over one beat at the bar line, plus a spatial offset
            // so the room reads as one gradient. `paletteColor` takes a 0…1
            // position across the whole palette, so entries are converted at
            // the last moment.
            let spread = config.colorChangeIntensity * (0.35 + spatialFidelity * 0.65)
            let paletteMotion = target.position * spread * Double(max(1, palette.count - 1))
                + paletteProgress + (isAccent && palette.count > 1 ? 1 : 0)
            var color = Self.paletteColor(palette, position: paletteMotion / Double(max(1, palette.count)))

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
                transitionDuration: silence ? 0.55 : (flashIntensity > 0 ? 0.04 : 0.09),
                priority: flashIntensity > 0 ? 3 : (isHit ? 2 : 1)
            ))
        }

        return MusicLightingFrame(
            states: states,
            timestamp: timestamp,
            sequenceNumber: sequenceNumber,
            sustainedEnergyEvent: sustainedEnergyEvent,
            flashApplied: flashIntensity > 0
        )
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

    /// Where the frame being rendered sits in the music.
    private struct MusicalClock {
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

    private func musicalClock(snapshot: AudioReactiveSnapshot, timestamp: TimeInterval) -> MusicalClock {
        let interval = snapshot.feltInterval > 0 ? snapshot.feltInterval : snapshot.beatInterval
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
        let predicted = timestamp + Self.outputLatencyCompensation + Self.attackTime * 0.8
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
        dt: Double
    ) {
        guard configuration.colorChangeIntensity > 0 else { lastPaletteHold = nil; return }
        if clock.strength > 0, clock.barRate > 0 {
            let barsPerColour = Double(max(1, Int((5 - configuration.colorChangeIntensity * 4).rounded())))
            let hold = Int(floor(clock.barPosition / barsPerColour))
            if let previous = lastPaletteHold, hold != previous {
                paletteFadeFrom = paletteProgress
                paletteFadeTo = paletteProgress + 1
                paletteFadeBar = clock.barPosition
            } else if lastPaletteHold == nil {
                // Reacquisition adopts the current colour. Never map a new grid
                // count directly onto the palette and teleport across entries.
                paletteFadeFrom = paletteProgress; paletteFadeTo = paletteProgress
                paletteFadeBar = clock.barPosition
            }
            lastPaletteHold = hold
            let blend = ((clock.barPosition - paletteFadeBar) * Double(clock.metre)).clamped01
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
        barsElapsed += (clock.barRate > 0 ? clock.barRate : 0.5) * dt
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
