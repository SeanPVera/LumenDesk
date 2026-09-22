import Foundation

// MARK: - What a fixture can show

/// What LumenDesk knows a fixture can do with a palette. Capability comes from
/// discovery — a Govee SKU's segment profile, a LIFX product ID — never from a
/// guess, so a light whose model is unknown is planned as a plain emitter and
/// still lights up.
enum ThemeFixtureCapability: Equatable {
    /// One emitter, one colour at a time. Every LIFX bulb that isn't a matrix
    /// product, and every Govee light without RGBIC segments.
    case solid
    /// Govee RGBIC: `count` addressable segments, optionally able to blend
    /// neighbours, optionally able to run only some zones at once.
    case segments(count: Int, gradient: Bool, simultaneousZoneLimit: Int?)
    /// A LIFX matrix product such as Luna. `width`/`height` are what the
    /// firmware reports; which cells are physically lit is decided by
    /// `LIFXMatrixState`.
    case matrix(productID: UInt32, width: Int, height: Int)
}

/// One target for a theme, in the order the room presents it.
struct ThemeFixture: Equatable {
    let id: String
    let capability: ThemeFixtureCapability
    /// White point to keep for low-saturation palette entries, where LIFX
    /// renders mostly from kelvin rather than from hue.
    var kelvin: Int = 3_500
    /// Zones this fixture is already running, for hardware that can only light
    /// some of them at once. A theme keeps the user's choice of zones instead
    /// of moving the light around the lamp.
    var preferredZones: [Int] = []

    init(id: String, capability: ThemeFixtureCapability,
         kelvin: Int = 3_500, preferredZones: [Int] = []) {
        self.id = id
        self.capability = capability
        self.kelvin = kelvin
        self.preferredZones = preferredZones
    }
}

// MARK: - What a fixture ended up showing

/// How much of the theme's spatial design the fixture could actually carry.
/// Every plan records one of these per fixture so the apply path can say what
/// happened instead of quietly dropping detail.
enum ThemeAdaptation: Equatable {
    /// The fixture spreads the palette across its own segments or zones.
    case spatial
    /// One emitter: it holds a single point of the design. Not a failure —
    /// it is what a bulb is — but it is why two bulbs in a gradient show two
    /// colours rather than a ramp each.
    case solidOnly
    /// The fixture has more zones than it can light at once, so the layout was
    /// trimmed to something it can show.
    case zoneLimited(lit: Int, of: Int)
}

struct ThemeFixturePlan: Equatable {
    let fixtureID: String
    /// Chroma for the fixture's solid colour. Callers send this at full value
    /// and carry level in `brightness`, so LIFX and Govee agree.
    let tone: PaletteTone
    /// Absolute 0…1 brightness for the fixture.
    let brightness: Double
    /// White point to send alongside a low-saturation tone.
    let kelvin: Int
    let segments: GoveeSegmentState?
    let matrix: LIFXMatrixState?
    let adaptation: ThemeAdaptation
}

struct ThemePlan: Equatable {
    let themeID: String
    let fixtures: [ThemeFixturePlan]

    var spatialCount: Int { fixtures.filter { $0.adaptation == .spatial }.count }
    var solidCount: Int { fixtures.filter { $0.adaptation == .solidOnly }.count }
    var zoneLimitedCount: Int {
        fixtures.filter {
            if case .zoneLimited = $0.adaptation { return true }
            return false
        }.count
    }

    /// One sentence naming any capability the room could not fully carry, or
    /// `nil` when everything showed the theme as designed. Deliberately not a
    /// warning: a room of plain bulbs is a normal room.
    var adaptationSummary: String? {
        var parts: [String] = []
        if spatialCount > 0 && solidCount > 0 {
            parts.append("\(solidCount) single-colour light\(solidCount == 1 ? "" : "s") hold one palette colour each")
        }
        for plan in fixtures {
            if case .zoneLimited(let lit, let total) = plan.adaptation {
                parts.append("one fixture lights \(lit) of its \(total) zones")
                break
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "."
    }
}

// MARK: - Planner

/// Turns a theme plus an ordered set of fixtures into exactly what each one
/// should be sent. Pure and free of transport concerns: `LightManager` decides
/// which commands carry the result, so the same plan covers direct apply,
/// preview, and tests.
enum ThemePlanner {
    /// A smooth ramp written segment-by-segment turns into one LAN packet per
    /// distinct colour on the durable Govee write path, which is fine for a
    /// 15-segment strip and hostile to a 200-bead string. Quantising the ramp
    /// bounds the packet batch, and a strip that blends its neighbours makes
    /// the steps invisible anyway.
    static let maximumGradientStops = 16

    /// Below this saturation a fixture is effectively emitting white, and LIFX
    /// renders it from kelvin rather than hue — so the palette entry has to
    /// carry a white point or a warm theme comes out cold.
    static let whitePointSaturation = 0.28

    static func plan(_ theme: LightingTheme, fixtures: [ThemeFixture]) -> ThemePlan {
        let palette = theme.normalizedTones
        guard !fixtures.isEmpty, !palette.isEmpty else {
            return ThemePlan(themeID: theme.id, fixtures: [])
        }

        var plans: [ThemeFixturePlan] = []
        plans.reserveCapacity(fixtures.count)
        for (index, fixture) in fixtures.enumerated() {
            plans.append(plan(theme, palette: palette, fixture: fixture,
                              position: index, of: fixtures.count))
        }
        return ThemePlan(themeID: theme.id, fixtures: plans)
    }

    // MARK: Per fixture

    private static func plan(_ theme: LightingTheme, palette: [PaletteTone],
                             fixture: ThemeFixture, position: Int, of total: Int) -> ThemeFixturePlan {
        switch fixture.capability {
        case .solid:
            let tone = soloTone(theme, palette: palette, position: position, of: total)
            return ThemeFixturePlan(
                fixtureID: fixture.id,
                tone: tone,
                brightness: brightness(theme, level: tone.level),
                kelvin: whitePoint(for: tone, fallback: fixture.kelvin),
                segments: nil,
                matrix: nil,
                adaptation: .solidOnly
            )

        case .segments(let count, let gradient, let zoneLimit):
            return segmentPlan(theme, palette: palette, fixture: fixture,
                               position: position, count: max(1, count),
                               canBlend: gradient, zoneLimit: zoneLimit)

        case .matrix(let productID, let width, let height):
            return matrixPlan(theme, palette: palette, fixture: fixture,
                              position: position, productID: productID,
                              width: width, height: height)
        }
    }

    /// The colour a single-emitter fixture takes.
    ///
    /// A lone bulb is the one case where the spatial design has nowhere to go,
    /// so it holds the theme's key colour at the theme's own brightness rather
    /// than whichever palette entry its position happened to land on. That is
    /// what makes a one-bulb room read as the theme instead of as one arbitrary
    /// slice of it.
    private static func soloTone(_ theme: LightingTheme, palette: [PaletteTone],
                                 position: Int, of total: Int) -> PaletteTone {
        guard total > 1 else {
            let key = palette[0]
            return PaletteTone(hue: key.hue, saturation: key.saturation, level: 1)
        }
        guard theme.distribution != .gradient else {
            return PaletteTone.ramp(palette, position: Double(position) / Double(total - 1))
        }
        let index = theme.distribution.paletteIndex(position: position, count: palette.count)
        return palette[min(index, palette.count - 1)]
    }

    private static func segmentPlan(_ theme: LightingTheme, palette: [PaletteTone],
                                    fixture: ThemeFixture, position: Int, count: Int,
                                    canBlend: Bool, zoneLimit: Int?) -> ThemeFixturePlan {
        let tones = spread(theme, palette: palette, over: count, fixtureIndex: position)
        var colors = tones.map { tone -> GoveeSegmentColor in
            let rgb = tone.rgb(atLevel: 1)
            return GoveeSegmentColor(red: rgb.red, green: rgb.green, blue: rgb.blue,
                                     brightness: tone.level, isOn: true)
        }

        var adaptation = ThemeAdaptation.spatial
        if let limit = zoneLimit, limit > 0, limit < count {
            let lit = litZones(preferred: fixture.preferredZones, limit: limit, count: count)
            for index in colors.indices { colors[index].isOn = lit.contains(index) }
            adaptation = .zoneLimited(lit: lit.count, of: count)
        }

        let state = GoveeSegmentState(colors: colors,
                                      gradient: canBlend && theme.distribution.blendsSegments,
                                      isActive: true)
        // The plan's representative tone is the strip's first colour rather
        // than an average of it: averaging a jewel palette gives mud, and this
        // tone is what picks the white point and drives previews.
        let tone = tones.first ?? palette[0]
        return ThemeFixturePlan(
            fixtureID: fixture.id,
            tone: tone,
            brightness: theme.brightness,
            kelvin: whitePoint(for: tone, fallback: fixture.kelvin),
            segments: state,
            matrix: nil,
            adaptation: adaptation
        )
    }

    private static func matrixPlan(_ theme: LightingTheme, palette: [PaletteTone],
                                   fixture: ThemeFixture, position: Int,
                                   productID: UInt32, width: Int, height: Int) -> ThemeFixturePlan {
        var state = LIFXMatrixState(productID: productID, width: width, height: height, colors: [])
        let zones = state.activeZoneIndices
        let tones = spread(theme, palette: palette, over: max(1, zones.count), fixtureIndex: position)
        for (offset, zone) in zones.enumerated() {
            guard state.colors.indices.contains(zone) else { continue }
            let tone = tones[min(offset, tones.count - 1)]
            // Matrix zones carry absolute brightness, so the theme's own level
            // folds in here rather than riding a separate device command.
            state.colors[zone] = LIFXMatrixColor(
                hue: channel(tone.hue),
                saturation: channel(tone.saturation),
                brightness: channel(brightness(theme, level: tone.level)),
                kelvin: UInt16(max(1_500, min(9_000, whitePoint(for: tone, fallback: fixture.kelvin))))
            )
        }
        state.isActive = true

        let tone = tones.first ?? palette[0]
        return ThemeFixturePlan(
            fixtureID: fixture.id,
            tone: tone,
            brightness: theme.brightness,
            kelvin: whitePoint(for: tone, fallback: fixture.kelvin),
            segments: nil,
            matrix: state,
            adaptation: .spatial
        )
    }

    // MARK: Spreading a palette along one fixture

    /// The palette laid out across `count` addressable positions inside one
    /// fixture, following the same distribution that placed colours across the
    /// room. `fixtureIndex` offsets the phase so two identical strips side by
    /// side don't come out as copies of each other.
    static func spread(_ theme: LightingTheme, palette: [PaletteTone],
                       over count: Int, fixtureIndex: Int = 0) -> [PaletteTone] {
        let count = max(1, count)
        let key = palette.first ?? PaletteTone(hue: 0, saturation: 0, level: 1)
        guard palette.count > 1 else { return Array(repeating: key, count: count) }
        let accents = palette.count - 1

        switch theme.distribution {
        case .wash:
            // A flat strip of one colour looks painted rather than lit, so the
            // second entry breathes through the middle at low contrast. The
            // theme still reads as one colour.
            let second = palette[1]
            return (0..<count).map { index in
                guard count > 1 else { return key }
                let position = Double(index) / Double(count - 1)
                let lean = 0.18 * (1 - abs(2 * position - 1))
                return PaletteTone.blend(key, second, fraction: lean)
            }

        case .gradient:
            let stops = max(2, min(count, maximumGradientStops))
            return (0..<count).map { index in
                guard count > 1 else { return key }
                let step = (index * (stops - 1) + (count - 1) / 2) / (count - 1)
                return PaletteTone.ramp(palette, position: Double(step) / Double(stops - 1))
            }

        case .anchored:
            let block = max(1, count / 9)
            return (0..<count).map { index in
                let slot = index / block + fixtureIndex
                guard slot % 3 == 1 else { return key }
                return palette[1 + ((slot / 3) % accents)]
            }

        case .alternating:
            let block = max(1, count / (palette.count * 2))
            return (0..<count).map { index in
                palette[(index / block + fixtureIndex) % palette.count]
            }

        case .scattered:
            let block = max(1, count / 12)
            return (0..<count).map { index in
                let slot = index / block + fixtureIndex
                return palette[theme.distribution.paletteIndex(position: slot, count: palette.count)]
            }
        }
    }

    // MARK: Helpers

    private static func brightness(_ theme: LightingTheme, level: Double) -> Double {
        max(0.01, min(1, theme.brightness * level))
    }

    private static func channel(_ value: Double) -> UInt16 {
        UInt16(max(0, min(65_535, (max(0, min(1, value)) * 65_535).rounded())))
    }

    /// Which zones a limited fixture lights. The user's current choice wins;
    /// otherwise transport order does, which is the same tiebreak
    /// `GoveeSegmentProfile.enforcingZoneLimit` uses.
    private static func litZones(preferred: [Int], limit: Int, count: Int) -> Set<Int> {
        var chosen: [Int] = []
        for zone in preferred where zone >= 0 && zone < count && !chosen.contains(zone) {
            chosen.append(zone)
            if chosen.count == limit { break }
        }
        var zone = 0
        while chosen.count < limit && zone < count {
            if !chosen.contains(zone) { chosen.append(zone) }
            zone += 1
        }
        return Set(chosen)
    }

    /// White point for a palette entry. Saturated colours ignore it, so this
    /// only matters for the near-white themes — and there it decides whether
    /// "warm neutral white" arrives warm or arrives at whatever the bulb was
    /// last set to.
    static func whitePoint(for tone: PaletteTone, fallback: Int) -> Int {
        guard tone.saturation < whitePointSaturation else { return fallback }
        switch tone.hue {
        case 0.88...1.0, 0.0..<0.14:
            return 2_500   // red through amber: candle and tungsten territory
        case 0.14..<0.22:
            return 3_200   // yellow: warm domestic white
        case 0.22..<0.47:
            return 4_000   // green: neutral, where a tint reads as daylight
        case 0.47..<0.72:
            return 6_000   // cyan through blue: overcast and cold
        default:
            return 5_000   // violet and magenta: cool without being clinical
        }
    }
}
