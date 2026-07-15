import Foundation

enum MusicModePreset: String, Codable, CaseIterable, Identifiable {
    case ambient
    case balanced
    case concert
    case cinematic
    case soundcheck
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ambient: return "Ambient"
        case .balanced: return "Balanced"
        case .concert: return "Concert"
        case .cinematic: return "Cinematic"
        case .soundcheck: return "Soundcheck"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .ambient: return "Slow color movement with restrained brightness and no flashes."
        case .balanced: return "Beat pulses, frequency color, and moderate movement."
        case .concert: return "Strong percussion accents and faster traveling motion."
        case .cinematic: return "Broad sweeps with gradual energy and infrequent bursts."
        case .soundcheck: return "The recognizable original beat-and-instrument response, made safer."
        case .custom: return "Your saved mapping, palette, limits, and topology behavior."
        }
    }
}

enum MusicMovementDirection: String, Codable, CaseIterable, Identifiable {
    case forward
    case reverse
    case alternating
    case expanding
    case contracting
    case clockwise
    case counterclockwise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .forward: return "Forward"
        case .reverse: return "Reverse"
        case .alternating: return "Alternating"
        case .expanding: return "Expanding"
        case .contracting: return "Contracting"
        case .clockwise: return "Clockwise"
        case .counterclockwise: return "Counterclockwise"
        }
    }
}

enum MusicSilenceBehavior: String, Codable, CaseIterable, Identifiable {
    case settle
    case holdPalette
    case fadeOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .settle: return "Settle to minimum"
        case .holdPalette: return "Hold a soft palette"
        case .fadeOut: return "Fade toward off"
        }
    }
}

struct MusicPaletteColor: Codable, Equatable, Hashable, Identifiable {
    var hex: UInt32
    var id: UInt32 { hex }

    init(_ hex: UInt32) {
        self.hex = hex & 0x00FF_FFFF
    }

    var rgb: (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }
}

struct MusicModeConfiguration: Codable, Equatable {
    var preset: MusicModePreset = .soundcheck
    var masterBrightness: Double = 0.82
    var effectIntensity: Double = 0.72
    var beatSensitivity: Double = 0.72
    var bassSensitivity: Double = 0.76
    var percussionSensitivity: Double = 0.68
    var colorChangeIntensity: Double = 0.66
    var movementAmount: Double = 0.58
    var movementDirection: MusicMovementDirection = .forward
    var movementSpeed: Double = 0.55
    var minimumBrightness: Double = 0.08
    var maximumBrightness: Double = 0.92
    var allowsFlashes: Bool = true
    var flashIntensity: Double = 0.42
    var maximumFlashFrequency: Double = 1.5
    var palette: [MusicPaletteColor] = Self.soundcheckPalette
    var silenceBehavior: MusicSilenceBehavior = .settle
    var photosensitivitySafeMode: Bool = true
    var restorePreviousState: Bool = true
    var usesSyntheticDemoPattern: Bool = false

    static let soundcheckPalette = [
        MusicPaletteColor(0xFF3B9D),
        MusicPaletteColor(0x7D5CFF),
        MusicPaletteColor(0x16D9D0),
        MusicPaletteColor(0xFFB52E)
    ]

    static let auroraPalette = [
        MusicPaletteColor(0x38E8D4),
        MusicPaletteColor(0x6D7CFF),
        MusicPaletteColor(0xB65CFF),
        MusicPaletteColor(0x2EA9FF)
    ]

    static let sunsetPalette = [
        MusicPaletteColor(0xFFD08A),
        MusicPaletteColor(0xFF8A4C),
        MusicPaletteColor(0xE34C73),
        MusicPaletteColor(0x753B8F)
    ]

    static let oceanPalette = [
        MusicPaletteColor(0x56E0D5),
        MusicPaletteColor(0x22AFCF),
        MusicPaletteColor(0x2867C7),
        MusicPaletteColor(0x15366E)
    ]

    static func configuration(for preset: MusicModePreset) -> MusicModeConfiguration {
        var value = MusicModeConfiguration()
        value.preset = preset
        switch preset {
        case .ambient:
            value.masterBrightness = 0.55
            value.effectIntensity = 0.32
            value.beatSensitivity = 0.28
            value.bassSensitivity = 0.42
            value.percussionSensitivity = 0.18
            value.colorChangeIntensity = 0.34
            value.movementAmount = 0.32
            value.movementSpeed = 0.2
            value.minimumBrightness = 0.12
            value.maximumBrightness = 0.62
            value.allowsFlashes = false
            value.flashIntensity = 0
            value.maximumFlashFrequency = 0
            value.palette = auroraPalette
            value.silenceBehavior = .holdPalette
        case .balanced:
            value.masterBrightness = 0.75
            value.effectIntensity = 0.62
            value.beatSensitivity = 0.68
            value.bassSensitivity = 0.7
            value.percussionSensitivity = 0.55
            value.colorChangeIntensity = 0.58
            value.movementAmount = 0.5
            value.movementSpeed = 0.48
            value.minimumBrightness = 0.1
            value.maximumBrightness = 0.84
            value.allowsFlashes = false
            value.flashIntensity = 0
            value.maximumFlashFrequency = 0
            value.palette = auroraPalette
        case .concert:
            value.masterBrightness = 0.9
            value.effectIntensity = 0.88
            value.beatSensitivity = 0.84
            value.bassSensitivity = 0.9
            value.percussionSensitivity = 0.86
            value.colorChangeIntensity = 0.82
            value.movementAmount = 0.86
            value.movementSpeed = 0.86
            value.minimumBrightness = 0.06
            value.maximumBrightness = 1
            value.allowsFlashes = true
            value.flashIntensity = 0.58
            value.maximumFlashFrequency = 2
            value.palette = soundcheckPalette
        case .cinematic:
            value.masterBrightness = 0.78
            value.effectIntensity = 0.7
            value.beatSensitivity = 0.48
            value.bassSensitivity = 0.68
            value.percussionSensitivity = 0.38
            value.colorChangeIntensity = 0.54
            value.movementAmount = 0.74
            value.movementSpeed = 0.28
            value.minimumBrightness = 0.08
            value.maximumBrightness = 0.9
            value.allowsFlashes = true
            value.flashIntensity = 0.34
            value.maximumFlashFrequency = 0.75
            value.palette = sunsetPalette
            value.silenceBehavior = .holdPalette
        case .soundcheck:
            break
        case .custom:
            value = configuration(for: .balanced)
            value.preset = .custom
        }
        return value.normalized()
    }

    func normalized(reducedMotion: Bool = false) -> MusicModeConfiguration {
        var value = self
        value.masterBrightness = value.masterBrightness.clamped01
        value.effectIntensity = value.effectIntensity.clamped01
        value.beatSensitivity = value.beatSensitivity.clamped01
        value.bassSensitivity = value.bassSensitivity.clamped01
        value.percussionSensitivity = value.percussionSensitivity.clamped01
        value.colorChangeIntensity = value.colorChangeIntensity.clamped01
        value.movementAmount = value.movementAmount.clamped01
        value.movementSpeed = value.movementSpeed.clamped01
        value.minimumBrightness = value.minimumBrightness.clamped01
        value.maximumBrightness = max(value.minimumBrightness, value.maximumBrightness.clamped01)
        value.flashIntensity = value.flashIntensity.clamped01
        value.maximumFlashFrequency = max(0, min(FlashSafetyLimiter.hardMaximumFrequency, value.maximumFlashFrequency))
        if value.palette.isEmpty { value.palette = Self.soundcheckPalette }
        // Keep the user's flash settings while Safe Mode is active so turning
        // it off after the explicit warning restores the chosen limits. The
        // safety gate still blocks every flash while Safe Mode is on.
        if reducedMotion {
            value.movementAmount = min(value.movementAmount, 0.18)
            value.movementSpeed = min(value.movementSpeed, 0.22)
            value.flashIntensity = 0
            value.maximumFlashFrequency = 0
        }
        return value
    }
}

enum FixtureTopologyLayout: String, Codable, CaseIterable, Identifiable {
    case leftToRight
    case frontToBack
    case circular
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftToRight: return "Left to right"
        case .frontToBack: return "Front to back"
        case .circular: return "Circular"
        case .custom: return "Custom order"
        }
    }
}

struct FixtureTopology: Codable, Equatable {
    var layout: FixtureTopologyLayout = .leftToRight
    var fixtureOrder: [String] = []

    func orderedFixtures(_ fixtures: [MusicFixtureDescriptor]) -> [MusicFixtureDescriptor] {
        let byID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.id, $0) })
        var seen = Set<String>()
        var ordered: [MusicFixtureDescriptor] = []
        for id in fixtureOrder where seen.insert(id).inserted {
            if let fixture = byID[id] { ordered.append(fixture) }
        }
        ordered.append(contentsOf: fixtures.filter { !seen.contains($0.id) }.sorted {
            let lhs = $0.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let rhs = $1.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        })
        return ordered
    }

    func expandedTargets(for fixtures: [MusicFixtureDescriptor]) -> [MusicSpatialTarget] {
        let ordered = orderedFixtures(fixtures)
        let count = ordered.reduce(0) { $0 + max(1, $1.segmentCount) }
        guard count > 0 else { return [] }
        var flatIndex = 0
        var result: [MusicSpatialTarget] = []
        for fixture in ordered {
            let segmentCount = max(1, fixture.segmentCount)
            for segment in 0..<segmentCount {
                let position: Double
                if layout == .circular {
                    position = Double(flatIndex) / Double(count)
                } else {
                    position = count == 1 ? 0.5 : Double(flatIndex) / Double(count - 1)
                }
                result.append(MusicSpatialTarget(
                    fixtureID: fixture.id,
                    segmentID: fixture.segmentCount > 0 ? segment : nil,
                    position: position
                ))
                flatIndex += 1
            }
        }
        return result
    }
}

enum MusicTransportKind: String, Codable, Equatable {
    case lifxLAN
    case goveeLAN
    case goveeRealtimeSegments
}

struct MusicFixtureDescriptor: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let transport: MusicTransportKind
    let segmentCount: Int

    init(id: String, label: String, transport: MusicTransportKind, segmentCount: Int = 0) {
        self.id = id
        self.label = label
        self.transport = transport
        self.segmentCount = max(0, segmentCount)
    }
}

struct MusicSpatialTarget: Codable, Equatable {
    let fixtureID: String
    let segmentID: Int?
    let position: Double
}

struct MusicLightingState: Equatable {
    let fixtureID: String
    let segmentID: Int?
    let hue: Double
    let saturation: Double
    let brightness: Double
    let transitionDuration: TimeInterval
    let priority: Int

    init(
        fixtureID: String,
        segmentID: Int? = nil,
        hue: Double,
        saturation: Double,
        brightness: Double,
        transitionDuration: TimeInterval,
        priority: Int = 0
    ) {
        self.fixtureID = fixtureID
        self.segmentID = segmentID
        self.hue = hue.wrappedUnit
        self.saturation = saturation.clamped01
        self.brightness = brightness.clamped01
        self.transitionDuration = max(0, transitionDuration)
        self.priority = priority
    }
}

struct MusicLightingFrame: Equatable {
    let states: [MusicLightingState]
    let timestamp: TimeInterval
    let sequenceNumber: UInt64
    let sustainedEnergyEvent: Bool
    let flashApplied: Bool
}

extension Double {
    fileprivate var clamped01: Double { max(0, min(1, self)) }
    fileprivate var wrappedUnit: Double {
        let value = truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }
}
