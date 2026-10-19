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
    /// A Nanoleaf Shapes wall: `count` individually addressable panels, which
    /// the caller orders along the wall as the user oriented it. Only walls
    /// whose arrangement the controller reported are planned this way.
    case panels(count: Int)
}

/// Directional vector for 2D spatial color-field interpolation across a room's floorplan.
enum SpatialFieldVector: String, CaseIterable, Codable, Equatable, Identifiable {
    case themeDefault
    case westToEast
    case northToSouth
    case radialCenter
    case diagonalSweep

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .themeDefault: return "Role"
        case .westToEast:   return "L → R"
        case .northToSouth: return "Back → Front"
        case .radialCenter: return "Radial"
        case .diagonalSweep: return "Diagonal"
        }
    }

    var displayName: String {
        switch self {
        case .themeDefault: return "Theme Role Harmony"
        case .westToEast:   return "Left to Right Wash"
        case .northToSouth: return "Back to Front Wash"
        case .radialCenter: return "Center Radial Bloom"
        case .diagonalSweep: return "Diagonal Studio Sweep"
        }
    }

    var icon: String {
        switch self {
        case .themeDefault: return "sparkles"
        case .westToEast:   return "arrow.left.and.right"
        case .northToSouth: return "arrow.up.and.down"
        case .radialCenter: return "dot.radiowaves.left.and.right"
        case .diagonalSweep: return "arrow.up.left.and.arrow.down.right"
        }
    }

    var summary: String {
        switch self {
        case .themeDefault:
            return "Assigns palette swatches by semantic fixture role and capability across the room."
        case .westToEast:
            return "Interpolates the palette continuously from left wall to right wall using 2D floorplan anchors."
        case .northToSouth:
            return "Sweeps the palette from back backdrop to front desk edge using 2D floorplan coordinates."
        case .radialCenter:
            return "Radiates the hero swatch from the room center outward toward perimeter fixtures."
        case .diagonalSweep:
            return "Projects a diagonal studio color gradient from top-left to bottom-right across the canvas."
        }
    }

    /// Computes normalized [0, 1] position within the 2D room color field for a given anchor.
    func fieldPosition(for anchor: PlanAnchor?, fallbackIndex: Int, total: Int) -> Double {
        guard let anchor else {
            guard total > 1 else { return 0 }
            return Double(fallbackIndex) / Double(total - 1)
        }
        // Normalize from PlanAnchor's [0.06, 0.94] usable range to [0, 1]
        let nx = min(1, max(0, (anchor.x - 0.06) / 0.88))
        let ny = min(1, max(0, (anchor.y - 0.06) / 0.88))
        switch self {
        case .themeDefault:
            guard total > 1 else { return 0 }
            return Double(fallbackIndex) / Double(total - 1)
        case .westToEast:
            return nx
        case .northToSouth:
            return ny
        case .radialCenter:
            let dx = nx - 0.5
            let dy = ny - 0.5
            return min(1, max(0, sqrt(dx * dx + dy * dy) / sqrt(0.5)))
        case .diagonalSweep:
            return min(1, max(0, (nx + ny) * 0.5))
        }
    }
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
    /// Optional 2D room-plan coordinate used by spatial color-field washes.
    var anchor: PlanAnchor? = nil

    init(id: String, capability: ThemeFixtureCapability,
         kelvin: Int = 3_500, preferredZones: [Int] = [],
         anchor: PlanAnchor? = nil) {
        self.id = id
        self.capability = capability
        self.kelvin = kelvin
        self.preferredZones = preferredZones
        self.anchor = anchor
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
    /// One tone per Shapes panel, in the spatial order the caller supplied.
    /// Tone level is that panel's own intensity; `brightness` stays on the
    /// controller's master brightness, so the level is applied exactly once.
    var panels: [PaletteTone]? = nil
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

    static func plan(
        _ theme: LightingTheme,
        fixtures: [ThemeFixture],
        spatialField: SpatialFieldVector = .themeDefault
    ) -> ThemePlan {
        let palette = theme.normalizedTones
        guard !fixtures.isEmpty, !palette.isEmpty else {
            return ThemePlan(themeID: theme.id, fixtures: [])
        }

        var plans: [ThemeFixturePlan] = []
        plans.reserveCapacity(fixtures.count)
        for (index, fixture) in fixtures.enumerated() {
            plans.append(plan(theme, palette: palette, fixture: fixture,
                              position: index, of: fixtures.count,
                              spatialField: spatialField))
        }
        return ThemePlan(themeID: theme.id, fixtures: plans)
    }

    /// Plans the Exact fixture brush. Each fixture receives the palette entry
    /// explicitly assigned to its stable device ID; an addressable fixture
    /// repeats that one entry across its own surface instead of inventing an
    /// alternating pattern. Missing assignments get a deterministic room-order
    /// default so a newly added fixture is immediately editable and visible.
    static func planExact(
        _ theme: LightingTheme,
        fixtures: [ThemeFixture],
        paletteIndices: [String: Int]
    ) -> ThemePlan {
        let palette = theme.normalizedTones
        guard !fixtures.isEmpty, !palette.isEmpty else {
            return ThemePlan(themeID: theme.id, fixtures: [])
        }

        let plans = fixtures.enumerated().map { position, fixture in
            let requested = paletteIndices[fixture.id] ?? position % palette.count
            let index = min(palette.count - 1, max(0, requested))
            return plan(theme, palette: [palette[index]], fixture: fixture,
                        position: 0, of: 1, preserveSingleToneLevel: true)
        }
        return ThemePlan(themeID: theme.id, fixtures: plans)
    }

    // MARK: Per fixture

    private static func plan(
        _ theme: LightingTheme,
        palette: [PaletteTone],
        fixture: ThemeFixture,
        position: Int,
        of total: Int,
        preserveSingleToneLevel: Bool = false,
        spatialField: SpatialFieldVector = .themeDefault
    ) -> ThemeFixturePlan {
        switch fixture.capability {
        case .solid:
            let tone = preserveSingleToneLevel
                ? palette[0]
                : soloTone(theme, palette: palette, fixture: fixture,
                           position: position, of: total, spatialField: spatialField)
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
                               position: position, of: total, count: max(1, count),
                               canBlend: gradient, zoneLimit: zoneLimit,
                               spatialField: spatialField)

        case .matrix(let productID, let width, let height):
            return matrixPlan(theme, palette: palette, fixture: fixture,
                              position: position, of: total, productID: productID,
                              width: width, height: height,
                              spatialField: spatialField)

        case .panels(let count):
            // Spread like segments: the same distribution rules that place
            // colours across a room place them across the wall.
            let tones = spreadForFixture(theme, palette: palette, fixture: fixture,
                                         over: max(1, count), fixtureIndex: position,
                                         totalFixtures: total, spatialField: spatialField)
            let tone = tones.first ?? palette[0]
            return ThemeFixturePlan(
                fixtureID: fixture.id,
                tone: tone,
                brightness: theme.brightness,
                kelvin: whitePoint(for: tone, fallback: fixture.kelvin),
                segments: nil,
                matrix: nil,
                adaptation: .spatial,
                panels: tones
            )
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
                                 fixture: ThemeFixture, position: Int, of total: Int,
                                 spatialField: SpatialFieldVector) -> PaletteTone {
        if spatialField != .themeDefault, fixture.anchor != nil {
            let fieldPos = spatialField.fieldPosition(for: fixture.anchor, fallbackIndex: position, total: total)
            return PaletteTone.ramp(palette, position: fieldPos)
        }
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

    private static func roomWindow(
        for fixture: ThemeFixture,
        fixtureIndex: Int,
        totalFixtures: Int,
        spatialField: SpatialFieldVector
    ) -> (center: Double, start: Double, end: Double) {
        let center = spatialField.fieldPosition(for: fixture.anchor, fallbackIndex: fixtureIndex, total: totalFixtures)
        let span = min(1.0, max(0.32, 1.0 / Double(max(1, totalFixtures))))
        let halfSpan = span * 0.5
        let startPos = max(0, min(1 - span, center - halfSpan))
        let endPos = min(1, startPos + span)
        return (center, startPos, endPos)
    }

    private static func spreadForFixture(
        _ theme: LightingTheme,
        palette: [PaletteTone],
        fixture: ThemeFixture,
        over count: Int,
        fixtureIndex: Int,
        totalFixtures: Int,
        spatialField: SpatialFieldVector
    ) -> [PaletteTone] {
        guard spatialField != .themeDefault, palette.count > 1 else {
            return spread(theme, palette: palette, over: count, fixtureIndex: fixtureIndex)
        }
        let safeCount = max(1, count)
        let window = roomWindow(for: fixture, fixtureIndex: fixtureIndex, totalFixtures: totalFixtures, spatialField: spatialField)
        let stops = max(2, min(safeCount, maximumGradientStops))
        return (0..<safeCount).map { index in
            guard safeCount > 1 else { return PaletteTone.ramp(palette, position: window.center) }
            let step = (index * (stops - 1) + (safeCount - 1) / 2) / (safeCount - 1)
            let localFraction = Double(step) / Double(stops - 1)
            let shapedFraction: Double
            if spatialField == .radialCenter {
                // Radiate from the middle segment outward toward both ends of the strip/wall
                shapedFraction = min(1, max(0, abs(localFraction - 0.5) * 2.0))
            } else {
                shapedFraction = localFraction
            }
            let fieldPos = window.start + (window.end - window.start) * shapedFraction
            return PaletteTone.ramp(palette, position: fieldPos)
        }
    }

    private static func segmentPlan(_ theme: LightingTheme, palette: [PaletteTone],
                                    fixture: ThemeFixture, position: Int, of total: Int, count: Int,
                                    canBlend: Bool, zoneLimit: Int?,
                                    spatialField: SpatialFieldVector) -> ThemeFixturePlan {
        let tones = spreadForFixture(theme, palette: palette, fixture: fixture,
                                     over: count, fixtureIndex: position,
                                     totalFixtures: total, spatialField: spatialField)
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

        let blends = spatialField != .themeDefault || theme.distribution.blendsSegments
        let state = GoveeSegmentState(colors: colors,
                                      gradient: canBlend && blends,
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
                                   fixture: ThemeFixture, position: Int, of total: Int,
                                   productID: UInt32, width: Int, height: Int,
                                   spatialField: SpatialFieldVector) -> ThemeFixturePlan {
        var state = LIFXMatrixState(productID: productID, width: width, height: height, colors: [])
        let zones = state.activeZoneIndices
        let window = roomWindow(for: fixture, fixtureIndex: position, totalFixtures: total, spatialField: spatialField)
        let fallbackTones = spread(theme, palette: palette, over: max(1, zones.count), fixtureIndex: position)
        var representativeTone: PaletteTone?

        for (offset, zone) in zones.enumerated() {
            guard state.colors.indices.contains(zone) else { continue }
            let tone: PaletteTone
            if spatialField != .themeDefault, palette.count > 1 {
                let row = zone / max(1, state.width)
                let col = zone % max(1, state.width)
                let nx = state.width > 1 ? Double(col) / Double(state.width - 1) : 0.5
                let ny = state.height > 1 ? Double(row) / Double(state.height - 1) : 0.5
                let localPos: Double
                switch spatialField {
                case .themeDefault:
                    localPos = Double(offset) / Double(max(1, zones.count - 1))
                case .westToEast:
                    localPos = nx
                case .northToSouth:
                    localPos = ny
                case .diagonalSweep:
                    localPos = min(1, max(0, (nx + ny) * 0.5))
                case .radialCenter:
                    let dx = nx - 0.5
                    let dy = ny - 0.5
                    localPos = min(1, max(0, sqrt(dx * dx + dy * dy) / sqrt(0.5)))
                }
                let fieldPos = window.start + (window.end - window.start) * localPos
                tone = PaletteTone.ramp(palette, position: fieldPos)
            } else {
                tone = fallbackTones[min(offset, fallbackTones.count - 1)]
            }
            if representativeTone == nil {
                representativeTone = tone
            }
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

        let tone = representativeTone ?? fallbackTones.first ?? palette[0]
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
