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
final class MusicChoreographyEngine {
    private var lastBeatCount = 0
    private var paletteStep = 0
    private var highEnergyBeganAt: TimeInterval?
    private var sustainedEnergyEvent = false
    private var lastTimestamp: TimeInterval?
    private var brightnessEnvelopes: [String: Double] = [:]
    private var flashLimiter = FlashSafetyLimiter()

    func reset() {
        lastBeatCount = 0
        paletteStep = 0
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

        if snapshot.beatCount < lastBeatCount {
            lastBeatCount = snapshot.beatCount
        } else if snapshot.beatCount > lastBeatCount {
            paletteStep += snapshot.beatCount - lastBeatCount
            lastBeatCount = snapshot.beatCount
        }

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
        let dt = max(1 / 120, min(0.25, timestamp - (lastTimestamp ?? timestamp - 1 / 30)))
        lastTimestamp = timestamp
        let upperBrightness = max(
            config.minimumBrightness,
            config.maximumBrightness * config.masterBrightness
        )
        let palette = config.palette.map(Self.hsb)
        let beatAlternation = (snapshot.beatCount / 2).isMultiple(of: 2) ? 1.0 : -1.0

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

            let phase = spatialPhase(
                position: target.position,
                timestamp: timestamp,
                direction: config.movementDirection,
                speed: config.movementSpeed,
                beatAlternation: beatAlternation
            )
            let wave = 0.5 + 0.5 * sin(phase * 2 * .pi)
            let spatialWeight = 1 - config.movementAmount + config.movementAmount * (0.3 + wave * 0.7)
            let bassDrive = snapshot.bass * config.bassSensitivity
            let beatDrive = max(snapshot.beat, snapshot.pulse) * config.beatSensitivity
            let sustainedLift = sustainedEnergyEvent ? 0.14 + snapshot.energy * 0.16 : 0
            var drive = 0.14
                + pow(max(snapshot.level, snapshot.energy), 0.65) * 0.32
                + bassDrive * 0.22
                + beatDrive * 0.26
                + roleOnset * 0.18
                + sustainedLift
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
            let release = 1 - exp(-dt / (silence ? 0.65 : 0.22))
            let coefficient = rawBrightness > previous ? attack : release
            var brightness = previous + (rawBrightness - previous) * coefficient
            brightness = min(1, brightness + flashIntensity * (1 - brightness))
            brightnessEnvelopes[envelopeKey] = brightness

            let paletteMotion = target.position * config.colorChangeIntensity * Double(max(1, palette.count - 1))
                + snapshot.mids * config.colorChangeIntensity
                + Double(paletteStep) * max(0.15, config.colorChangeIntensity)
            var color = Self.paletteColor(palette, position: paletteMotion)
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

    private func spatialPhase(
        position: Double,
        timestamp: TimeInterval,
        direction: MusicMovementDirection,
        speed: Double,
        beatAlternation: Double
    ) -> Double {
        let time = timestamp * (0.18 + speed * 1.7)
        switch direction {
        case .forward, .clockwise: return position - time
        case .reverse, .counterclockwise: return position + time
        case .alternating: return position - time * beatAlternation
        case .expanding: return abs(position - 0.5) * 2 - time
        case .contracting: return abs(position - 0.5) * 2 + time
        }
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
