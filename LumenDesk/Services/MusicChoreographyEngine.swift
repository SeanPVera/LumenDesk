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
/// The engine choreographs against musical time, not wall-clock time. When
/// `AudioReactiveSnapshot` carries a locked tempo, brightness swells are shaped
/// by the position inside the beat, sweeps traverse the room once per bar, and
/// the palette advances on bar lines. Every one of those was previously driven
/// by raw onsets or by `timestamp` alone, which is what made dense material
/// read as fast flashing that happened to coincide with music rather than
/// choreography that followed it.
///
/// Material with no detectable pulse — ambient, spoken word, sparse acoustic —
/// keeps the energy-driven behavior. `MusicalClock.strength` cross-fades
/// between the two so a track that drifts in and out of a clear beat does not
/// snap between two different shows.
final class MusicChoreographyEngine {
    /// Roughly how long a frame takes to leave the renderer, cross the LAN, and
    /// light a fixture. On a predicted beat grid the show can be evaluated that
    /// far ahead so the swell lands *on* the beat instead of just after it.
    private static let outputLatencyCompensation: TimeInterval = 0.045

    private var lastBeatCount = 0
    private var paletteProgress: Double = 0
    private var movementPhase: Double = 0
    private var barsElapsed: Double = 0
    private var highEnergyBeganAt: TimeInterval?
    private var sustainedEnergyEvent = false
    private var lastTimestamp: TimeInterval?
    private var brightnessEnvelopes: [String: Double] = [:]
    private var flashLimiter = FlashSafetyLimiter()

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
    }

    func makeFrame(
        snapshot: AudioReactiveSnapshot,
        configuration: MusicModeConfiguration,
        topology: FixtureTopology,
        fixtures: [MusicFixtureDescriptor],
        timestamp: TimeInterval,
        sequenceNumber: UInt64,
        reducedMotion: Bool = false
    ) -> MusicLightingFrame {
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
        advancePalette(newBeats: newBeats, clock: clock, configuration: config, dt: dt)
        advanceMovement(clock: clock, configuration: config, dt: dt)

        let beganSustainedEvent = updateSustainedEnergy(snapshot.energy, at: timestamp)
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

        let silence = snapshot.confidence < 0.025 && snapshot.level < 0.025 && snapshot.energy < 0.035
        let upperBrightness = max(
            config.minimumBrightness,
            config.maximumBrightness * config.masterBrightness
        )
        let palette = config.palette.map(Self.hsb)
        // On the grid, a pulse is shaped by where the frame sits inside the
        // beat: it swells into the beat, peaks on it, and decays across it, and
        // the downbeat is accented. Off the grid it is the onset envelope, as
        // before.
        let reactivePulse = max(snapshot.beat, snapshot.pulse)
        let musicalPulse = beatShape(phase: clock.phase)
            * Self.barAccent(clock.beatInBar)
            * min(1, 0.4 + snapshot.energy * 0.8)
        let pulseDrive = reactivePulse + (musicalPulse - reactivePulse) * clock.strength

        var states: [MusicLightingState] = []
        states.reserveCapacity(targets.count)
        for (index, target) in targets.enumerated() {
            let role = index % 3
            let roleOnset: Double
            switch role {
            case 0: roleOnset = snapshot.kick * config.bassSensitivity
            case 1: roleOnset = snapshot.snare * config.percussionSensitivity
            default: roleOnset = snapshot.percussion * config.percussionSensitivity
            }

            let phase = spatialPhase(position: target.position, direction: config.movementDirection)
            let wave = 0.5 + 0.5 * sin(phase * 2 * .pi)
            let spatialWeight = 1 - config.movementAmount + config.movementAmount * (0.3 + wave * 0.7)
            let bassDrive = snapshot.bass * config.bassSensitivity
            let sustainedLift = sustainedEnergyEvent ? 0.14 + snapshot.energy * 0.16 : 0
            // Split into where the fixture rests between hits and how far a beat
            // lifts it. The swing is the larger half, and large enough that a
            // strong beat reaches the top of the configured range.
            //
            // The previous weighting made continuous loudness the biggest term,
            // so fixtures sat at a bright mid-level that the beat could only
            // nudge: busy, but never legibly on the beat.
            let sustain = 0.1
                + pow(max(snapshot.level, snapshot.energy), 0.65) * 0.2
                + bassDrive * 0.14
            let swing = pulseDrive * (0.35 + config.beatSensitivity * 0.8)
            var drive = sustain + swing + roleOnset * 0.12 + sustainedLift
            drive = min(1, drive * (0.55 + config.effectIntensity * 0.65) * spatialWeight)

            if silence {
                switch config.silenceBehavior {
                case .settle: drive = 0
                case .holdPalette: drive = 0.08 + config.effectIntensity * 0.08
                case .fadeOut: drive = -0.1
                }
            }

            let rawBrightness = max(
                config.silenceBehavior == .fadeOut && silence ? 0 : config.minimumBrightness,
                config.minimumBrightness + (upperBrightness - config.minimumBrightness) * max(0, drive)
            )
            let envelopeKey = "\(target.fixtureID)#\(target.segmentID ?? -1)"
            let previous = brightnessEnvelopes[envelopeKey] ?? rawBrightness
            let attack = 1 - exp(-dt / 0.045)
            // On the grid the decay is a fraction of the beat, so one pulse
            // finishes well before the next arrives at any tempo rather than
            // smearing into it at fast tempos or leaving a gap at slow ones.
            // The musical envelope is already a smooth shape, so it wants far
            // less smoothing than the onset-driven drive does: at the old
            // constant the light barely came down between beats and the pulse
            // flattened into a glow.
            let musicalRelease = min(0.3, max(0.06, clock.interval * 0.12))
            let releaseTime = silence ? 0.65 : (0.22 + (musicalRelease - 0.22) * clock.strength)
            let release = 1 - exp(-dt / releaseTime)
            let coefficient = rawBrightness > previous ? attack : release
            var brightness = previous + (rawBrightness - previous) * coefficient
            brightness = min(1, brightness + flashIntensity * (1 - brightness))
            brightnessEnvelopes[envelopeKey] = brightness

            // Palette progression is measured in palette entries and quantized:
            // the colour is held for the whole musical division and cross-fades
            // quickly at its boundary, so a change reads as landing on the
            // music rather than as a continuous drift or a per-transient
            // flicker. `paletteColor` takes a 0…1 position across the whole
            // palette, so entries are converted at the last moment.
            let entries = Double(max(1, palette.count))
            let paletteMotion = target.position * config.colorChangeIntensity * Double(max(1, palette.count - 1))
                + quantizedPaletteProgress(strength: clock.strength)
            var color = Self.paletteColor(palette, position: paletteMotion / entries)
            color.hue = (color.hue + (snapshot.mood - 0.5) * 0.12).wrappedUnit

            if role == 1 && roleOnset > 0.42 {
                // Snare/clap: a complementary, lower-saturation accent. It is
                // not a flash unless the independent limiter admitted one.
                color.hue = (color.hue + 0.5).wrappedUnit
                color.saturation *= 0.72
            } else if role == 2 && roleOnset > 0.38 {
                color.hue = (color.hue + 0.08).wrappedUnit
                color.saturation = min(1, color.saturation + 0.12)
            }
            if flashIntensity > 0 {
                color.saturation *= 1 - flashIntensity * 0.8
            }

            states.append(MusicLightingState(
                fixtureID: target.fixtureID,
                segmentID: target.segmentID,
                hue: color.hue,
                saturation: color.saturation,
                brightness: brightness,
                transitionDuration: silence ? 0.55 : (flashIntensity > 0 ? 0.04 : 0.1),
                priority: flashIntensity > 0 ? 3 : (roleOnset > 0.4 ? 2 : 1)
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
        /// 0…1 position inside the current beat, 0 exactly on the beat.
        var phase: Double = 0
        /// Which beat of an assumed four-beat bar this is.
        var beatInBar: Int = 0
        /// Seconds per beat, or 0 when there is no usable grid.
        var interval: TimeInterval = 0
        /// How far to trust the grid: 0 renders the energy-driven show, 1 the
        /// fully beat-synchronized one, and values between cross-fade.
        var strength: Double = 0
        /// Bars per second, 0 when there is no usable grid.
        var barRate: Double = 0
    }

    private func musicalClock(snapshot: AudioReactiveSnapshot, timestamp: TimeInterval) -> MusicalClock {
        guard snapshot.isTempoLocked,
              snapshot.beatInterval > 0,
              snapshot.beatReferenceTime > 0 else { return MusicalClock() }
        // A reference this old means analysis stopped feeding the grid (capture
        // ended, the audio went silent). Extrapolating from it would drift, so
        // fall back to the reactive show instead.
        guard timestamp - snapshot.beatReferenceTime < snapshot.beatInterval * 6 else { return MusicalClock() }

        // Evaluating slightly ahead is only meaningful on a predicted grid: it
        // pays for the transport and firmware delay so the swell lands on the
        // beat rather than a frame or two behind it.
        let predicted = timestamp + Self.outputLatencyCompensation
        let beats = (predicted - snapshot.beatReferenceTime) / snapshot.beatInterval
        let wholeBeats = floor(beats)
        let beatInBar = Int(((Double(snapshot.beatInBar) + wholeBeats)
            .truncatingRemainder(dividingBy: Double(BeatTracker.beatsPerBar))
            + Double(BeatTracker.beatsPerBar))
            .truncatingRemainder(dividingBy: Double(BeatTracker.beatsPerBar)))
        return MusicalClock(
            phase: beats - wholeBeats,
            beatInBar: beatInBar,
            interval: snapshot.beatInterval,
            strength: max(0, min(1, snapshot.beatConfidence * 1.6)),
            barRate: 1 / (snapshot.beatInterval * Double(BeatTracker.beatsPerBar))
        )
    }

    /// Brightness contour across one beat: a short swell into the beat, a peak
    /// on it, then a decay across the rest.
    private func beatShape(phase: Double) -> Double {
        let decay = pow(max(0, 1 - phase), 2.6)
        let anticipation = phase > 0.82 ? pow((phase - 0.82) / 0.18, 2) * 0.55 : 0
        return max(decay, anticipation)
    }

    /// Relative weight of each beat in a four-beat bar. Accenting one and three
    /// — the downbeat most — is what makes a run of pulses read as a groove
    /// rather than as a metronome.
    private static func barAccent(_ beatInBar: Int) -> Double {
        switch beatInBar {
        case 0: return 1
        case 2: return 0.88
        default: return 0.74
        }
    }

    /// Advances palette progression, measured in palette entries: on a grid it
    /// moves by musical time so a change lands on a bar line, and off one it
    /// still steps per detected beat.
    ///
    /// Progression used to be fed straight into a position that wraps across
    /// the *whole* palette, so a single beat could advance the room by two or
    /// three colours and the palette cycled about every other beat. Counting
    /// entries makes "one colour per bar" mean exactly that.
    private func advancePalette(
        newBeats: Int,
        clock: MusicalClock,
        configuration: MusicModeConfiguration,
        dt: Double
    ) {
        if clock.strength > 0, clock.barRate > 0 {
            let entriesPerBar = 0.25 + configuration.colorChangeIntensity * 1.75
            paletteProgress += entriesPerBar * clock.barRate * dt
        } else if newBeats > 0 {
            paletteProgress += Double(newBeats) * max(0.15, configuration.colorChangeIntensity)
        }
    }

    /// Holds the palette for the whole division and cross-fades over the last
    /// sliver of it, so the change lands on a bar line. Off the grid the
    /// progression stays continuous, matching the previous behavior.
    private func quantizedPaletteProgress(strength: Double) -> Double {
        guard strength > 0 else { return paletteProgress }
        let step = floor(paletteProgress)
        let fraction = paletteProgress - step
        let crossfade = min(1, fraction / 0.15)
        let quantized = step + crossfade
        return paletteProgress + (quantized - paletteProgress) * strength
    }

    /// Integrates the sweep rate rather than deriving an absolute phase from
    /// the clock, so gaining or losing tempo lock changes the speed of the
    /// motion without ever jumping its position.
    private func advanceMovement(clock: MusicalClock, configuration: MusicModeConfiguration, dt: Double) {
        let wallClockRate = 0.18 + configuration.movementSpeed * 1.7
        var rate = wallClockRate
        if clock.strength > 0, clock.barRate > 0 {
            // Traverses per bar, so a sweep arrives on the downbeat instead of
            // drifting across it.
            let traversesPerBar = 0.25 + configuration.movementSpeed * 1.75
            let musicalRate = traversesPerBar * clock.barRate
            rate = wallClockRate + (musicalRate - wallClockRate) * clock.strength
        }
        barsElapsed += (clock.barRate > 0 ? clock.barRate : 0.5) * dt
        if configuration.movementDirection == .alternating {
            // Reverse on the bar line while locked. Without a grid there are no
            // bars, so fall back to flipping every four detected beats, which is
            // the cadence the show used before.
            let bar = clock.strength > 0 ? Int(floor(barsElapsed)) : lastBeatCount / BeatTracker.beatsPerBar
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
        return HSB(
            hue: (palette[low].hue + hueDelta * fraction).wrappedUnit,
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
}
