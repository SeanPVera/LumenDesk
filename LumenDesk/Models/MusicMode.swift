import Foundation

enum MusicModePreset: String, Codable, CaseIterable, Identifiable {
    case ambient
    case balanced
    case concert
    case cinematic
    case soundcheck
    case club
    case halftime
    case waltz
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ambient: return "Ambient"
        case .balanced: return "Balanced"
        case .concert: return "Concert"
        case .cinematic: return "Cinematic"
        case .soundcheck: return "Soundcheck"
        case .club: return "Club"
        case .halftime: return "Half-time"
        case .waltz: return "Waltz"
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
        case .club: return "Four-on-the-floor wash plus a hard hit layer on the downbeat."
        case .halftime: return "Felt pulse on every other beat. Head-nod, not strobe."
        case .waltz: return "Three-count swell. Downbeat takes the room, two and three breathe."
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

/// Musical metre Music Mode can lock to. Four-four remains the default.
enum MusicMetre: Int, Codable, CaseIterable, Identifiable {
    case three = 3
    case four = 4
    case five = 5
    case six = 6
    case seven = 7

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .three: return "3/4"
        case .four: return "4/4"
        case .five: return "5/4"
        case .six: return "6/8"
        case .seven: return "7/8"
        }
    }
}

enum TimeFeel: String, Codable, CaseIterable, Identifiable {
    case auto
    case straight
    case half
    case double

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .straight: return "Straight"
        case .half: return "Half-time"
        case .double: return "Double-time"
        }
    }

    var intervalMultiplier: Double {
        switch self {
        case .auto, .straight: return 1
        case .half: return 2
        case .double: return 0.5
        }
    }
}

enum FixtureRole: String, Codable, CaseIterable, Identifiable {
    case auto
    case wash
    case hit
    case accent
    case motion
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .wash: return "Wash"
        case .hit: return "Hit"
        case .accent: return "Accent"
        case .motion: return "Motion"
        case .off: return "Off"
        }
    }

    var summary: String {
        switch self {
        case .auto: return "Assigned from the fixture: RGBIC becomes motion, downstage becomes hit, rear becomes accent, otherwise wash."
        case .wash: return "Room fill. Softer swing, holds the palette."
        case .hit: return "Downbeat punch. Harder swing, follows the kick."
        case .accent: return "Complementary colour on snare and percussion."
        case .motion: return "Travels the room. RGBIC segments continue the path."
        case .off: return "Left out of this show without changing its current state."
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
    /// `nil` lets the metre tracker choose. Saved archives without this key stay auto.
    var metreOverride: MusicMetre? = nil
    var timeFeel: TimeFeel = .auto
    var stereoImage: Double = 0.7
    var phraseAware: Bool = true

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

    static let clubPalette = [
        MusicPaletteColor(0xFF2D6A),
        MusicPaletteColor(0x7C5CFF),
        MusicPaletteColor(0x21C4DE),
        MusicPaletteColor(0xF6FAFF)
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
        case .club:
            value.masterBrightness = 0.88
            value.effectIntensity = 0.8
            value.beatSensitivity = 0.9
            value.bassSensitivity = 0.86
            value.percussionSensitivity = 0.7
            value.colorChangeIntensity = 0.48
            value.movementAmount = 0.7
            value.movementSpeed = 0.64
            value.metreOverride = .four
            value.timeFeel = .straight
            value.palette = clubPalette
        case .halftime:
            value.masterBrightness = 0.78
            value.effectIntensity = 0.7
            value.beatSensitivity = 0.8
            value.bassSensitivity = 0.84
            value.percussionSensitivity = 0.5
            value.colorChangeIntensity = 0.4
            value.movementAmount = 0.42
            value.movementSpeed = 0.28
            value.timeFeel = .half
            value.palette = sunsetPalette
        case .waltz:
            value.masterBrightness = 0.7
            value.effectIntensity = 0.58
            value.beatSensitivity = 0.62
            value.bassSensitivity = 0.55
            value.percussionSensitivity = 0.32
            value.colorChangeIntensity = 0.5
            value.movementAmount = 0.48
            value.movementSpeed = 0.3
            value.metreOverride = .three
            value.timeFeel = .straight
            value.palette = oceanPalette
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
        value.stereoImage = value.stereoImage.clamped01
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

extension MusicModeConfiguration {
    private enum CodingKeys: String, CodingKey {
        case preset, masterBrightness, effectIntensity, beatSensitivity
        case bassSensitivity, percussionSensitivity, colorChangeIntensity
        case movementAmount, movementDirection, movementSpeed
        case minimumBrightness, maximumBrightness, allowsFlashes
        case flashIntensity, maximumFlashFrequency, palette, silenceBehavior
        case photosensitivitySafeMode, restorePreviousState, usesSyntheticDemoPattern
        case metreOverride, timeFeel, stereoImage, phraseAware
    }

    // Field-by-field so archives saved before metre, feel, stereo, and phrase
    // keys existed still decode instead of the whole configuration falling
    // back to Soundcheck (the PersistenceStore `try?` default).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? container.decode(MusicModePreset.self, forKey: .preset)) ?? .soundcheck
        masterBrightness = (try? container.decode(Double.self, forKey: .masterBrightness)) ?? 0.82
        effectIntensity = (try? container.decode(Double.self, forKey: .effectIntensity)) ?? 0.72
        beatSensitivity = (try? container.decode(Double.self, forKey: .beatSensitivity)) ?? 0.72
        bassSensitivity = (try? container.decode(Double.self, forKey: .bassSensitivity)) ?? 0.76
        percussionSensitivity = (try? container.decode(Double.self, forKey: .percussionSensitivity)) ?? 0.68
        colorChangeIntensity = (try? container.decode(Double.self, forKey: .colorChangeIntensity)) ?? 0.66
        movementAmount = (try? container.decode(Double.self, forKey: .movementAmount)) ?? 0.58
        movementDirection = (try? container.decode(MusicMovementDirection.self, forKey: .movementDirection)) ?? .forward
        movementSpeed = (try? container.decode(Double.self, forKey: .movementSpeed)) ?? 0.55
        minimumBrightness = (try? container.decode(Double.self, forKey: .minimumBrightness)) ?? 0.08
        maximumBrightness = (try? container.decode(Double.self, forKey: .maximumBrightness)) ?? 0.92
        allowsFlashes = (try? container.decode(Bool.self, forKey: .allowsFlashes)) ?? true
        flashIntensity = (try? container.decode(Double.self, forKey: .flashIntensity)) ?? 0.42
        maximumFlashFrequency = (try? container.decode(Double.self, forKey: .maximumFlashFrequency)) ?? 1.5
        palette = (try? container.decode([MusicPaletteColor].self, forKey: .palette)) ?? Self.soundcheckPalette
        silenceBehavior = (try? container.decode(MusicSilenceBehavior.self, forKey: .silenceBehavior)) ?? .settle
        photosensitivitySafeMode = (try? container.decode(Bool.self, forKey: .photosensitivitySafeMode)) ?? true
        restorePreviousState = (try? container.decode(Bool.self, forKey: .restorePreviousState)) ?? true
        usesSyntheticDemoPattern = (try? container.decode(Bool.self, forKey: .usesSyntheticDemoPattern)) ?? false
        metreOverride = try? container.decode(MusicMetre.self, forKey: .metreOverride)
        timeFeel = (try? container.decode(TimeFeel.self, forKey: .timeFeel)) ?? .auto
        stereoImage = (try? container.decode(Double.self, forKey: .stereoImage)) ?? 0.7
        phraseAware = (try? container.decode(Bool.self, forKey: .phraseAware)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(masterBrightness, forKey: .masterBrightness)
        try container.encode(effectIntensity, forKey: .effectIntensity)
        try container.encode(beatSensitivity, forKey: .beatSensitivity)
        try container.encode(bassSensitivity, forKey: .bassSensitivity)
        try container.encode(percussionSensitivity, forKey: .percussionSensitivity)
        try container.encode(colorChangeIntensity, forKey: .colorChangeIntensity)
        try container.encode(movementAmount, forKey: .movementAmount)
        try container.encode(movementDirection, forKey: .movementDirection)
        try container.encode(movementSpeed, forKey: .movementSpeed)
        try container.encode(minimumBrightness, forKey: .minimumBrightness)
        try container.encode(maximumBrightness, forKey: .maximumBrightness)
        try container.encode(allowsFlashes, forKey: .allowsFlashes)
        try container.encode(flashIntensity, forKey: .flashIntensity)
        try container.encode(maximumFlashFrequency, forKey: .maximumFlashFrequency)
        try container.encode(palette, forKey: .palette)
        try container.encode(silenceBehavior, forKey: .silenceBehavior)
        try container.encode(photosensitivitySafeMode, forKey: .photosensitivitySafeMode)
        try container.encode(restorePreviousState, forKey: .restorePreviousState)
        try container.encode(usesSyntheticDemoPattern, forKey: .usesSyntheticDemoPattern)
        try container.encodeIfPresent(metreOverride, forKey: .metreOverride)
        try container.encode(timeFeel, forKey: .timeFeel)
        try container.encode(stereoImage, forKey: .stereoImage)
        try container.encode(phraseAware, forKey: .phraseAware)
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
    /// Fixtures the user has excluded from this scope's show. They keep
    /// whatever state they were already in — Music Mode never powers them,
    /// snapshots them for restore, or sends them frames.
    var excludedFixtureIDs: Set<String> = []
    /// Per-fixture choreography roles, keyed by stable device ID. Missing
    /// entries resolve as `.auto`.
    var roles: [String: FixtureRole] = [:]

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

    /// `fixtures` with excluded ones and `.off` roles removed, keeping the rest
    /// in `fixtureOrder` order. Positions are then spread across only the
    /// included fixtures, so excluding one closes the gap it would otherwise
    /// leave in the spatial sweep rather than leaving a dark hole in it.
    func includedFixtures(_ fixtures: [MusicFixtureDescriptor]) -> [MusicFixtureDescriptor] {
        orderedFixtures(fixtures).filter {
            !excludedFixtureIDs.contains($0.id) && $0.resolvedRole != .off
        }
    }

    func expandedTargets(for fixtures: [MusicFixtureDescriptor]) -> [MusicSpatialTarget] {
        let ordered = includedFixtures(fixtures)
        let count = ordered.reduce(0) { $0 + max(1, $1.segmentCount) }
        guard count > 0 else { return [] }
        var flatIndex = 0
        var result: [MusicSpatialTarget] = []
        for fixture in ordered {
            let segmentCount = max(1, fixture.segmentCount)
            let role = fixture.resolvedRole
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
                    position: position,
                    role: role
                ))
                flatIndex += 1
            }
        }
        return result
    }

    func role(for fixtureID: String) -> FixtureRole {
        roles[fixtureID] ?? .auto
    }
}

extension FixtureTopology {
    private enum CodingKeys: String, CodingKey {
        case layout, fixtureOrder, excludedFixtureIDs, roles
    }

    // Decoded field-by-field, tolerant of a missing `excludedFixtureIDs` or
    // `roles` key, so topologies saved before those fields existed still
    // decode instead of the whole per-scope entry falling back to a blank
    // default (losing the user's saved fixture order). Defined in an
    // extension so the compiler still synthesizes the memberwise initializer
    // used elsewhere (e.g. `FixtureTopology()`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? container.decode(FixtureTopologyLayout.self, forKey: .layout)) ?? .leftToRight
        fixtureOrder = (try? container.decode([String].self, forKey: .fixtureOrder)) ?? []
        excludedFixtureIDs = (try? container.decode(Set<String>.self, forKey: .excludedFixtureIDs)) ?? []
        roles = (try? container.decode([String: FixtureRole].self, forKey: .roles)) ?? [:]
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
    let role: FixtureRole

    init(
        id: String,
        label: String,
        transport: MusicTransportKind,
        segmentCount: Int = 0,
        role: FixtureRole = .auto
    ) {
        self.id = id
        self.label = label
        self.transport = transport
        self.segmentCount = max(0, segmentCount)
        self.role = role
    }

    /// Explicit roles win; `.auto` is assigned from the fixture itself so a
    /// new room still layers without the user tagging every light.
    var resolvedRole: FixtureRole {
        if role != .auto { return role }
        if segmentCount > 0 { return .motion }
        let folded = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if id.localizedCaseInsensitiveContains("kick") || folded.contains("downstage") { return .hit }
        if id.localizedCaseInsensitiveContains("accent") || folded.contains("rear") { return .accent }
        return .wash
    }
}

struct MusicSpatialTarget: Codable, Equatable {
    let fixtureID: String
    let segmentID: Int?
    let position: Double
    let role: FixtureRole
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

// MARK: - Plain-language help
//
// Everything below is user-facing copy, written for someone who has never run
// a lighting desk and does not know what "wash", "metre" or "topology" mean.
// The existing `summary` strings stay as they are — those describe the show in
// the language of the feature. `plainSummary` is what the interface leads
// with, and it is the string the README's plain-English guide mirrors.

extension MusicModePreset {
    /// What this preset feels like in the room, and when to pick it.
    var plainSummary: String {
        switch self {
        case .ambient:
            return "Quiet background glow. Colors drift slowly and nothing jumps out at you. Good for dinner, reading, or a room where the lights should not steal attention."
        case .balanced:
            return "The everyday setting. Lights pulse with the beat, change color as the music changes, and move a little. Start here if you are not sure what you want."
        case .concert:
            return "Loud and punchy. Drums land hard and color travels across the room quickly. Built for a party."
        case .cinematic:
            return "Slow, wide swells that build and release. Suits film scores, ambient records, and anything with long build-ups."
        case .soundcheck:
            return "The look LumenDesk shipped with before Music Mode, kept the same but without the harsh flashing."
        case .club:
            return "Steady pulse on every beat with a hard punch on the first beat of each bar. Made for dance music with a constant kick drum."
        case .halftime:
            return "Pulses on every other beat, so the room nods along instead of strobing. Good for hip-hop and anything slow and heavy."
        case .waltz:
            return "Counts in threes. The first beat takes the room, the next two breathe. For waltzes, jazz in three, and a lot of folk music."
        case .custom:
            return "Your own settings. Moving any slider or switch below saves the result here, and it stays put until you change it again."
        }
    }

    /// The short "what am I listening to?" line shown beside the preset.
    var bestFor: String {
        switch self {
        case .ambient: return "Dinner and background music"
        case .balanced: return "Anything, if you are unsure"
        case .concert: return "Rock, pop, parties"
        case .cinematic: return "Scores and ambient"
        case .soundcheck: return "The old LumenDesk look"
        case .club: return "House, techno, dance"
        case .halftime: return "Hip-hop and slow, heavy music"
        case .waltz: return "Music that counts in threes"
        case .custom: return "Your saved settings"
        }
    }
}

extension FixtureRole {
    /// What this one light does during the show.
    var plainSummary: String {
        switch self {
        case .auto:
            return "Let LumenDesk choose. Strips get the traveling color, lights near you take the punch, lights behind you take the second color, and everything else fills the room."
        case .wash:
            return "Fills the room with light. Bright and steady, with a soft pulse underneath."
        case .hit:
            return "Punches on the beat. Give this to the light you want the kick drum to land in."
        case .accent:
            return "Answers the snare and cymbals in a second color. Works best on a light off to one side."
        case .motion:
            return "Colour runs across it in time with the music. Best on a strip or any light with segments."
        case .off:
            return "Sits this song out. It keeps whatever it is showing right now and Music Mode never touches it."
        }
    }
}

extension MusicSilenceBehavior {
    /// What the lights do when the music stops.
    var plainSummary: String {
        switch self {
        case .settle: return "When the music stops, the lights sink to their dimmest setting and wait."
        case .holdPalette: return "When the music stops, the lights hold a soft color instead of dropping away."
        case .fadeOut: return "When the music stops, the lights fade down toward off."
        }
    }
}

extension MusicMetre {
    /// What the time signature means without reading music.
    var plainSummary: String {
        switch self {
        case .three: return "Three beats to a bar. Waltz time."
        case .four: return "Four beats to a bar. Most pop, rock and dance music."
        case .five: return "Five beats to a bar. Unusual, and it will feel like it."
        case .six: return "Six quick beats, felt as two groups of three."
        case .seven: return "Seven beats to a bar. Deliberately lopsided."
        }
    }
}

extension TimeFeel {
    /// How fast the room should feel compared to the beat.
    var plainSummary: String {
        switch self {
        case .auto: return "LumenDesk decides how fast the room should feel."
        case .straight: return "One pulse for every beat."
        case .half: return "One pulse every two beats. Slower and heavier."
        case .double: return "Two pulses for every beat. Faster and busier."
        }
    }
}

extension MusicMovementDirection {
    /// Which way color travels across your lights.
    var plainSummary: String {
        switch self {
        case .forward: return "Travels from the first light in your list to the last."
        case .reverse: return "Travels from the last light back to the first."
        case .alternating: return "Travels one way, then comes back the other."
        case .expanding: return "Starts in the middle of the room and spreads outward."
        case .contracting: return "Starts at the outside and closes toward the middle."
        case .clockwise: return "Circles the room one way. Set the layout to Circular first."
        case .counterclockwise: return "Circles the room the other way. Set the layout to Circular first."
        }
    }
}

extension FixtureTopologyLayout {
    /// How to describe where the lights are without the word "topology".
    var plainSummary: String {
        switch self {
        case .leftToRight: return "List your lights the way they sit across the room, left side first."
        case .frontToBack: return "List your lights from the closest to the furthest away."
        case .circular: return "Your lights ring the room, so the last one sits next to the first."
        case .custom: return "Your own order. Use the arrows to move a light up or down the list."
        }
    }
}

/// Plain-language copy for the Music Mode controls that are not enum cases:
/// the sliders, the switches, the audio sources, and the first-run walkthrough.
/// Kept in one place so the whole body of writing can be reviewed at once.
enum MusicModeHelp {
    /// Three sentences that get a first-time user to a working show.
    struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    static var quickStart: [Step] {
        #if os(macOS)
        return [
            Step(id: 1,
                 title: "Play something",
                 detail: "Start music in any app on this Mac. LumenDesk listens to the sound your Mac is already playing, so Spotify, YouTube, a DJ set and a game all work the same way. The first time you press Start, macOS asks for Screen Recording permission — that is the only way an app is allowed to hear your Mac's audio, and nothing is recorded or saved."),
            Step(id: 2,
                 title: "Pick a room and a preset",
                 detail: "Choose which lights are in the show at the top right, then pick a preset. Balanced is the safe first choice. You can change presets while the music is playing."),
            Step(id: 3,
                 title: "Press Start Music Mode",
                 detail: "The meters below start moving and your lights follow the music. Press Stop when you are done and the lights go back to how you left them.")
        ]
        #else
        return [
            Step(id: 1,
                 title: "Play something out loud",
                 detail: "On iPhone and iPad, Music Mode listens through the microphone, so the music has to be audible in the room. Grant microphone access the first time you press Start. Nothing is recorded or saved. If you want to follow a track the microphone cannot hear, use Open Audio File instead."),
            Step(id: 2,
                 title: "Pick a room and a preset",
                 detail: "Choose which lights are in the show at the top, then pick a preset. Balanced is the safe first choice. You can change presets while the music is playing."),
            Step(id: 3,
                 title: "Press Start Music Mode",
                 detail: "The meters below start moving and your lights follow the music. Press Stop when you are done and the lights go back to how you left them.")
        ]
        #endif
    }

    /// What the beat readout is telling you.
    static let readout = "The bars show what LumenDesk is hearing right now: overall volume, then bass, mids and highs. The dot flashes on each beat. Once it works out the tempo — usually about four seconds of steady rhythm — the label under it changes from \"Beat\" to the speed in beats per minute and how many beats are in a bar. While it still reads \"Beat\", the lights are reacting to the music as it happens instead of following a count, which is normal for ambient, spoken word and free-time playing."

    static let masterBrightness = "How bright the show gets overall. Turn it down late at night, up for a bright room."
    static let effectIntensity = "How dramatic the show is. Low is a gentle shimmer; high swings hard between dark and bright."
    static let beatSensitivity = "How strongly the lights answer the beat. Turn it up if the room feels flat, down if it feels twitchy."
    static let bassSensitivity = "How much the low end — kick drum and bass — drives the lights."
    static let percussionSensitivity = "How much snares, hats and claps show up as accents."
    static let colorChangeIntensity = "How often the color changes. Low holds one color for a long time; high moves through the palette quickly."
    static let movementAmount = "How far color travels across your lights. At zero, every light does the same thing at the same time."
    static let movementSpeed = "How fast that travel crosses the room."
    static let minimumBrightness = "The dimmest the lights are allowed to go between beats. Raise it if the room keeps going too dark."
    static let maximumBrightness = "The brightest a beat is allowed to push the lights."
    static let allowsFlashes = "Lets the show use short, sharp flashes on big moments. Off unless you turn safe mode off first."
    static let flashIntensity = "How strong those flashes are."
    static let maximumFlashFrequency = "The most flashes allowed per second. LumenDesk never goes above three per second no matter what this says."
    static let photosensitivitySafeMode = "On by default. Blocks flashing outright, because flashing light can trigger seizures and migraines in some people. Leave it on unless you know everyone in the room is fine with it."
    static let palette = "The set of colors the show picks from. It changes the mood more than any other single control."
    static let stereoImage = "How much the left and right of the recording spread across your room. At zero the whole room reacts as one; turn it up and lights on the left follow the left channel."
    static let phraseAware = "Lets the show notice when a section is building and lift with it, instead of treating every bar the same."
    static let restorePreviousState = "When you press Stop, put every light back exactly how it was before the show started."
    static let reducedMotion = "If Reduced Motion is on in your system accessibility settings, LumenDesk keeps movement small and never flashes."

    #if os(macOS)
    static let systemAudioSource = "Listens to whatever this Mac is playing — any app, not just a music app. Needs Screen Recording permission, which is how macOS gates access to system audio."
    #else
    static let systemAudioSource = "Listens through the microphone, so the music has to be audible in the room. Needs microphone permission."
    #endif
    static let fileSource = "Pick a song file and LumenDesk plays it and lights to it. Useful on iPhone and iPad, or when you want one specific track rather than everything the device is playing."
    static let midiSource = "Follows a beat sent by DJ software, a drum machine, or recording software over MIDI. Use this when you want the lights locked to that clock instead of working the tempo out by ear."

    static let roles = "Every light gets a job. Auto picks one for you and is fine for most rooms — change a light's job only if you want that specific light doing something else."
    static let order = "Movement runs down this list in order, so the list should match where the lights actually sit in the room. Use the arrows to reorder, and the eye button to leave a light out of the show entirely."
    static let sharedSource = "Every room in a show listens to the same audio source. To run a second room, start it on the same source; to switch sources, stop the shows that are already running."
}
