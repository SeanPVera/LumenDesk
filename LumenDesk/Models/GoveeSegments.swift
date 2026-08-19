import Foundation
import SwiftUI

// MARK: - Segment capability catalog

/// Physical layout of a segmented Govee light. Drives how the Segment Studio
/// draws the device (continuous strip, COB bar, bulbs on a wire, or lamp zones) and which
/// controls make sense (only blended strips expose the gradient toggle).
enum GoveeSegmentLayout: String, Codable {
    case stripLight    // flexible RGBIC/RGBICW tape strip
    case cobStrip      // continuous chip-on-board strip; colors can blend
    case stringLights  // discrete bulbs or clusters along a wire
    case curtain       // vertical curtain strands edited as LAN-addressable columns
    case neonRope      // flexible neon tube; behaves like a fine-grained strip
    case lamp          // independently addressable lighting zones in a lamp
    case generic       // unrecognized RGBIC device

    var displayName: String {
        switch self {
        case .stripLight: return "Strip light"
        case .cobStrip: return "COB strip"
        case .stringLights: return "String lights"
        case .curtain: return "Curtain lights"
        case .neonRope: return "Neon rope"
        case .lamp: return "Segmented lamp"
        case .generic: return "RGBIC light"
        }
    }

    var icon: String {
        switch self {
        case .stripLight: return "lightswitch.on"
        case .cobStrip: return "rectangle.split.3x1.fill"
        case .stringLights: return "party.popper.fill"
        case .curtain: return "rectangle.grid.3x2.fill"
        case .neonRope: return "scribble.variable"
        case .lamp: return "lamp.floor.fill"
        case .generic: return "lightbulb.led.fill"
        }
    }
}

/// The physical unit drawn for a string-light profile. Christmas strings use
/// dense LED beads; patio strings use larger, individually addressable bulbs.
enum GoveeStringLightStyle: Equatable {
    case bead
    case bulb

    var unitName: String {
        switch self {
        case .bead: return "bead"
        case .bulb: return "bulb"
        }
    }

    var unitsPerEditorRow: Int {
        switch self {
        case .bead: return 20
        case .bulb: return 15
        }
    }
}

/// What LumenDesk knows about a Govee model's segment hardware. Counts mirror
/// what the Govee Home app exposes for that family; unknown models fall back
/// to a profile the user can correct with the segment-count stepper.
struct GoveeSegmentProfile {
    let layout: GoveeSegmentLayout
    let defaultSegmentCount: Int
    let supportsGradient: Bool
    /// True when the SKU matched the catalog, false for the generic fallback.
    let recognized: Bool
    /// Families whose firmware ignores the static Bluetooth-format segment
    /// write — Govee's own platform API reports no segment capability for
    /// them (multi-zone lamps, string, curtain, and permanent-outdoor lights). Their layouts
    /// are held on the light through the razer streaming overlay instead,
    /// and LumenDesk re-asserts the held frame on refresh ticks and device
    /// recovery.
    var appliesViaStream: Bool = false
    /// Hardware-defined topologies, such as the H60B0's three lamps, cannot
    /// be resized by the user.
    var hasFixedSegmentCount: Bool = false
    /// Physical labels in transport order. Empty for interchangeable strip
    /// segments and other fixtures whose units do not need individual names.
    var zoneNames: [String] = []
    /// Compact labels for the same zones, used where the full name is too
    /// long (zone-combination chips). Falls back to `zoneNames`.
    var zoneShortNames: [String] = []
    /// How many zones the fixture can light at the same time, when that is
    /// fewer than it has. The H60B0 uplighter drives two of its three lamps
    /// at a time — the same restriction the Govee Home app enforces — so a
    /// layout that lights all three is not something the hardware can show.
    /// Nil for fixtures that can run every segment at once.
    var simultaneousZoneLimit: Int? = nil
    /// Physical presentation for string lights. Nil for every other layout.
    var stringLightStyle: GoveeStringLightStyle?

    var editorUnitName: String {
        if let stringLightStyle { return stringLightStyle.unitName }
        switch layout {
        case .lamp: return "zone"
        case .curtain: return "column"
        default: return "segment"
        }
    }

    var maximumEditorSegmentCount: Int {
        max(defaultSegmentCount, GoveeProtocol.maxSegments)
    }

    /// True when the fixture has more zones than it can light at once, so the
    /// user has to choose which ones run.
    var limitsSimultaneousZones: Bool {
        guard let simultaneousZoneLimit else { return false }
        return simultaneousZoneLimit > 0 && simultaneousZoneLimit < defaultSegmentCount
    }

    /// Physical name for a zone, falling back to a number for fixtures whose
    /// units are interchangeable.
    func zoneName(_ index: Int) -> String {
        zoneNames.indices.contains(index) ? zoneNames[index] : "\(editorUnitName.capitalized) \(index + 1)"
    }

    /// Short form of `zoneName(_:)` for tight controls.
    func zoneShortName(_ index: Int) -> String {
        zoneShortNames.indices.contains(index) ? zoneShortNames[index] : zoneName(index)
    }

    /// Known segmented families. Exact SKUs first, then prefix families.
    /// Sources: Govee Home app segment editors and the community LAN/BLE
    /// protocol work (govee2mqtt, OpenRGB, homebridge-govee).
    ///
    /// Built imperatively (one `add` call per row) rather than as a single
    /// large dictionary/array literal of `.init(...)` calls: Swift's type
    /// checker solves a collection literal as one expression, and a few
    /// dozen struct-initializer elements in one literal can blow up into
    /// minutes of compile time and tens of gigabytes of RAM. Independent
    /// statements are each checked in isolation and stay fast regardless of
    /// how many rows the catalog grows to.
    static func detect(sku: String?) -> GoveeSegmentProfile? {
        guard let sku = sku?.uppercased(), sku.hasPrefix("H") else { return nil }
        if let profile = exactMatches[sku] { return profile }
        return prefixMatches.first { sku.hasPrefix($0.prefix) }?.profile
    }

    private static let exactMatches: [String: GoveeSegmentProfile] = {
        var rows: [String: GoveeSegmentProfile] = [:]
        func add(_ sku: String, _ layout: GoveeSegmentLayout, _ count: Int, _ gradient: Bool,
                 stream: Bool = false, fixed: Bool = false, zoneNames: [String] = [],
                 zoneShortNames: [String] = [], zoneLimit: Int? = nil,
                 stringStyle: GoveeStringLightStyle? = nil) {
            rows[sku] = GoveeSegmentProfile(
                layout: layout,
                defaultSegmentCount: count,
                supportsGradient: gradient,
                recognized: true,
                appliesViaStream: stream,
                hasFixedSegmentCount: fixed,
                zoneNames: zoneNames,
                zoneShortNames: zoneShortNames,
                simultaneousZoneLimit: zoneLimit,
                stringLightStyle: stringStyle
            )
        }
        // Flexible RGBIC / RGBICW interior strips
        // Strip Light S H612B is the 24.6-foot/7.5-metre variant. Govee Home
        // exposes ten addressable sections per metre, for 75 editable zones.
        // Its segment layout is held through the real-time stream.
        add("H612B", .stripLight, 75, true, stream: true)
        // RGBIC / COB interior strips
        add("H619A", .cobStrip, 15, true)
        add("H619B", .cobStrip, 15, true)
        add("H619C", .cobStrip, 15, true)
        add("H619D", .cobStrip, 15, true)
        add("H619E", .cobStrip, 15, true)
        add("H619Z", .cobStrip, 15, true)
        add("H61C2", .cobStrip, 15, true)
        add("H61C3", .cobStrip, 15, true)
        add("H61C5", .cobStrip, 15, true)
        add("H61E1", .cobStrip, 15, true)
        add("H6172", .cobStrip, 15, true)
        // Neon ropes
        add("H61A0", .neonRope, 20, true)
        add("H61A1", .neonRope, 20, true)
        add("H61A2", .neonRope, 20, true)
        add("H61A3", .neonRope, 20, true)
        add("H61A5", .neonRope, 20, true)
        add("H61D0", .neonRope, 20, true)
        // Uplighter floor lamp: upper ripple, middle ambient, and lower daily
        // zones are independently addressable and held through streaming.
        // The lamp only drives two of the three at once, so the studio treats
        // "which two are lit" as part of the layout.
        add("H60B0", .lamp, 3, false, stream: true, fixed: true,
            zoneNames: ["Upper Ripple", "Middle Ambient", "Lower Daily Illumination"],
            zoneShortNames: ["Upper", "Middle", "Lower"],
            zoneLimit: 2)
        // Christmas String Lights: Govee's Uni-IC controller addresses every
        // physical bead. H70C1 is 33 ft / 100 beads; H70C2 and H70C4 are
        // 66 ft / 200 beads. Their fixed topology is held via streaming.
        add("H70C1", .stringLights, 100, false, stream: true, fixed: true, stringStyle: .bead)
        add("H70C2", .stringLights, 200, false, stream: true, fixed: true, stringStyle: .bead)
        add("H70C4", .stringLights, 200, false, stream: true, fixed: true, stringStyle: .bead)
        // Outdoor bulb strings. H7028 can accept an optional second 15-bulb
        // strand, so its count remains adjustable; H7021 ships with 30 bulbs.
        add("H7020", .stringLights, 15, false, stream: true, stringStyle: .bulb)
        add("H7021", .stringLights, 30, false, stream: true, stringStyle: .bulb)
        add("H7028", .stringLights, 15, false, stream: true, stringStyle: .bulb)
        // H70B1 is a 20-column curtain, not a one-dimensional string. The LAN
        // stream addresses columns; the 520-bead pixel canvas remains a Govee
        // Home feature.
        add("H70B1", .curtain, 20, false, stream: true, fixed: true)
        add("H70BC", .curtain, 20, false, stream: true, fixed: true)
        return rows
    }()

    private static let prefixMatches: [(prefix: String, profile: GoveeSegmentProfile)] = {
        var rows: [(prefix: String, profile: GoveeSegmentProfile)] = []
        func add(_ prefix: String, _ layout: GoveeSegmentLayout, _ count: Int, _ gradient: Bool,
                 stream: Bool = false, fixed: Bool = false,
                 stringStyle: GoveeStringLightStyle? = nil) {
            rows.append((prefix, GoveeSegmentProfile(
                layout: layout,
                defaultSegmentCount: count,
                supportsGradient: gradient,
                recognized: true,
                appliesViaStream: stream,
                hasFixedSegmentCount: fixed,
                stringLightStyle: stringStyle
            )))
        }
        add("H619", .cobStrip, 15, true)
        add("H61C", .cobStrip, 15, true)
        add("H61E", .cobStrip, 15, true)
        add("H61A", .neonRope, 20, true)
        add("H61B", .neonRope, 20, true)
        add("H61D", .neonRope, 20, true)
        add("H70C", .stringLights, 20, false, stream: true, stringStyle: .bead)
        add("H70B", .curtain, 20, false, stream: true, fixed: true)
        add("H702", .stringLights, 15, false, stream: true, stringStyle: .bulb)
        add("H705", .stringLights, 15, false, stream: true, stringStyle: .bulb) // permanent outdoor nodes
        return rows
    }()

    /// Fallback shown when the user opens the studio for an unrecognized SKU.
    static let generic = GoveeSegmentProfile(layout: .generic, defaultSegmentCount: 15,
                                             supportsGradient: true, recognized: false,
                                             stringLightStyle: nil)
}

// MARK: - Per-segment state

/// One segment's color and its individual brightness (the Govee Home app
/// allows both per segment), plus whether the fixture is lighting it at all.
struct GoveeSegmentColor: Equatable {
    var red: Double        // 0…1
    var green: Double      // 0…1
    var blue: Double       // 0…1
    var brightness: Double // 0…1
    /// Per-segment power. A switched-off segment keeps its color for when it
    /// comes back on and renders dark in the meantime — that is how fixtures
    /// like the H60B0 uplighter, which can only run some of their zones at
    /// once, express which zones are in use.
    var isOn: Bool

    init(red: Double, green: Double, blue: Double, brightness: Double = 1.0, isOn: Bool = true) {
        self.red = max(0, min(1, red))
        self.green = max(0, min(1, green))
        self.blue = max(0, min(1, blue))
        self.brightness = max(0, min(1, brightness))
        self.isOn = isOn
    }

    init(color: Color, brightness: Double = 1.0, isOn: Bool = true) {
        let rgb = color.rgbComponents
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b, brightness: brightness, isOn: isOn)
    }

    init(hex: UInt, brightness: Double = 1.0, isOn: Bool = true) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  brightness: brightness,
                  isOn: isOn)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    /// Color with the segment's own brightness folded in, for previews. A
    /// switched-off segment reads as unlit.
    var litColor: Color {
        guard isOn else { return Color(red: 0, green: 0, blue: 0) }
        return Color(red: red * max(0.05, brightness),
                     green: green * max(0.05, brightness),
                     blue: blue * max(0.05, brightness))
    }
    var rgb255: (r: Int, g: Int, b: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// What the fixture is asked to show: the held color, or black while the
    /// segment is switched off. Every transport renders from this.
    var renderedRGB255: (r: Int, g: Int, b: Int) { isOn ? rgb255 : (0, 0, 0) }
    /// Grouping key so identical colors share one LAN packet. Switched-off
    /// segments group together whatever colors they are holding.
    var packetKey: String {
        let c = renderedRGB255
        return "\(c.r):\(c.g):\(c.b)"
    }
    var brightnessPercent: Int { max(1, min(100, Int((brightness * 100).rounded()))) }

    /// The same color with its power flag set — used where power belongs to
    /// the fixture rather than to the color, such as saved presets.
    func settingPower(_ on: Bool) -> GoveeSegmentColor {
        var copy = self
        copy.isOn = on
        return copy
    }

    static func interpolate(_ from: GoveeSegmentColor, _ to: GoveeSegmentColor, fraction: Double) -> GoveeSegmentColor {
        let t = max(0, min(1, fraction))
        return GoveeSegmentColor(red: from.red + (to.red - from.red) * t,
                                 green: from.green + (to.green - from.green) * t,
                                 blue: from.blue + (to.blue - from.blue) * t,
                                 brightness: from.brightness + (to.brightness - from.brightness) * t,
                                 isOn: t < 0.5 ? from.isOn : to.isOn)
    }
}

extension GoveeSegmentColor: Codable {
    enum CodingKeys: String, CodingKey { case red, green, blue, brightness, isOn }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let red = try c.decode(Double.self, forKey: .red)
        let green = try c.decode(Double.self, forKey: .green)
        let blue = try c.decode(Double.self, forKey: .blue)
        let brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? 1.0
        let isOn = (try? c.decode(Bool.self, forKey: .isOn)) ?? true
        self.init(red: red, green: green, blue: blue, brightness: brightness, isOn: isOn)
    }
}

/// The full segment layout for one device, persisted per device ID and
/// captured into scenes/undo so multi-color layouts round-trip.
struct GoveeSegmentState: Codable, Equatable {
    var colors: [GoveeSegmentColor]
    /// Blend neighboring segment colors into each other (COB strips).
    var gradient: Bool
    /// True while the device's most recent color-type command was a segment
    /// layout. Solid colors, white mode, and effects flip this off so scenes
    /// and undo know which representation to restore.
    var isActive: Bool

    var segmentCount: Int { colors.count }

    /// Indexes of the segments the fixture is lighting, in transport order.
    var poweredSegments: [Int] { colors.indices.filter { colors[$0].isOn } }
    var poweredCount: Int { colors.reduce(0) { $0 + ($1.isOn ? 1 : 0) } }
    /// True when the layout would leave the fixture completely dark.
    var isFullyDark: Bool { !colors.isEmpty && poweredCount == 0 }

    /// Switches one segment on or off, keeping the color it is holding.
    mutating func setPower(_ on: Bool, at index: Int) {
        guard colors.indices.contains(index) else { return }
        colors[index].isOn = on
    }

    /// Lights exactly the listed segments and switches the rest off.
    mutating func setPoweredSegments<S: Sequence>(_ powered: S) where S.Element == Int {
        let lit = Set(powered)
        for index in colors.indices {
            colors[index].isOn = lit.contains(index)
        }
    }

    init(colors: [GoveeSegmentColor], gradient: Bool = false, isActive: Bool = false) {
        self.colors = colors
        self.gradient = gradient
        self.isActive = isActive
    }

    /// A fresh layout seeded from the device's current solid color.
    static func seed(count: Int, color: Color, gradient: Bool) -> GoveeSegmentState {
        GoveeSegmentState(colors: Array(repeating: GoveeSegmentColor(color: color), count: max(1, count)),
                          gradient: gradient)
    }

    /// Resize while keeping the existing paint job recognizable: stretches or
    /// shrinks the current colors across the new count.
    mutating func resize(to count: Int) {
        let target = max(1, count)
        guard target != colors.count, !colors.isEmpty else { return }
        if colors.count == 1 {
            colors = Array(repeating: colors[0], count: target)
            return
        }
        let source = colors
        colors = (0..<target).map { index in
            let position = Double(index) / Double(max(1, target - 1)) * Double(source.count - 1)
            let low = Int(position.rounded(.down)), high = min(source.count - 1, low + 1)
            return GoveeSegmentColor.interpolate(source[low], source[high], fraction: position - Double(low))
        }
    }

    /// Average of the segment colors — used for the device's status dot.
    /// Switched-off segments don't count toward it, so the dot matches what
    /// the fixture is actually showing; an all-dark layout falls back to the
    /// colors it is holding rather than reporting black.
    var blendedColor: Color {
        let lit = colors.filter(\.isOn)
        let source = lit.isEmpty ? colors : lit
        guard !source.isEmpty else { return .white }
        let n = Double(source.count)
        return Color(red: source.map(\.red).reduce(0, +) / n,
                     green: source.map(\.green).reduce(0, +) / n,
                     blue: source.map(\.blue).reduce(0, +) / n)
    }

    /// Segment indexes grouped by identical color, ordered by first segment.
    /// One LAN packet is sent per group.
    var colorGroups: [(color: GoveeSegmentColor, segments: [Int])] {
        var order: [String] = []
        var groups: [String: (color: GoveeSegmentColor, segments: [Int])] = [:]
        for (index, segment) in colors.enumerated() {
            if groups[segment.packetKey] == nil {
                order.append(segment.packetKey)
                groups[segment.packetKey] = (segment, [])
            }
            groups[segment.packetKey]?.segments.append(index)
        }
        return order.compactMap { groups[$0] }
    }

    /// Segment indexes grouped by identical per-segment brightness percent.
    var brightnessGroups: [(percent: Int, segments: [Int])] {
        var order: [Int] = []
        var groups: [Int: [Int]] = [:]
        for (index, segment) in colors.enumerated() {
            let percent = segment.brightnessPercent
            if groups[percent] == nil { order.append(percent); groups[percent] = [] }
            groups[percent]?.append(index)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

extension GoveeSegmentProfile {
    /// Repairs saved drafts created before a fixture's hardware topology was
    /// known. Adjustable strips keep the user's chosen segment count, and any
    /// layout lighting more zones than the fixture can run at once is trimmed
    /// down to something it can actually show.
    func normalizedEditorState(_ state: GoveeSegmentState) -> GoveeSegmentState {
        var normalized = state
        if hasFixedSegmentCount, normalized.segmentCount != defaultSegmentCount {
            normalized.resize(to: defaultSegmentCount)
        }
        return enforcingZoneLimit(normalized)
    }

    /// Switches zones off until the layout lights no more than the fixture can
    /// run at once, and returns it unchanged for fixtures without that limit.
    ///
    /// `keeping` lists zones in the order they should survive: the studio
    /// passes the order zones were switched on, newest first, so the zone that
    /// has been lit longest is the one that gives way when the user turns
    /// another on. Zones it doesn't mention fall back to transport order.
    func enforcingZoneLimit(_ state: GoveeSegmentState, keeping priority: [Int] = []) -> GoveeSegmentState {
        guard let limit = simultaneousZoneLimit, limit > 0 else { return state }
        let powered = state.poweredSegments
        guard powered.count > limit else { return state }
        let poweredSet = Set(powered)
        var ranked = priority.filter { poweredSet.contains($0) }
        ranked += powered.filter { !ranked.contains($0) }
        var next = state
        next.setPoweredSegments(ranked.prefix(limit))
        return next
    }

    /// Every set of zones the fixture can light at once, in transport order —
    /// the studio offers them as one-tap combinations ("Upper + Lower").
    /// Empty for fixtures without a limit, and for ones with too many zones
    /// for the combinations to be a useful list.
    var zoneCombinations: [[Int]] {
        guard limitsSimultaneousZones, let limit = simultaneousZoneLimit,
              defaultSegmentCount <= 4 else { return [] }
        var result: [[Int]] = []
        var current: [Int] = []
        func walk(from start: Int) {
            if current.count == limit {
                result.append(current)
                return
            }
            for index in start..<defaultSegmentCount {
                current.append(index)
                walk(from: index + 1)
                current.removeLast()
            }
        }
        walk(from: 0)
        return result
    }
}

// MARK: - Segment presets

/// A reusable multi-color paint job. Stops are rendered onto however many
/// segments the target device has — smoothly interpolated (sunset-style
/// washes) or repeated as a pattern (candy-cane-style alternation).
struct GoveeSegmentPreset: Identifiable, Codable, Equatable {
    enum Fill: String, Codable {
        case smooth     // interpolate stops across the strip
        case repeating  // tile the stops segment by segment
    }

    let id: UUID
    var name: String
    var stops: [GoveeSegmentColor]
    var fill: Fill

    init(id: UUID = UUID(), name: String, stops: [GoveeSegmentColor], fill: Fill = .smooth) {
        self.id = id
        self.name = name
        self.stops = stops
        self.fill = fill
    }

    /// Renders the preset onto `count` segments. A preset is a paint job, not
    /// a power state — which segments are lit belongs to the fixture, so every
    /// rendered stop comes back powered and callers reapply their own layout's
    /// on/off pattern.
    func colors(for count: Int) -> [GoveeSegmentColor] {
        let target = max(1, count)
        guard !stops.isEmpty else { return Array(repeating: GoveeSegmentColor(hex: 0xFFFFFF), count: target) }
        let painted: [GoveeSegmentColor]
        switch fill {
        case .repeating:
            painted = (0..<target).map { stops[$0 % stops.count] }
        case .smooth:
            if stops.count > 1, target > 1 {
                painted = (0..<target).map { index in
                    let position = Double(index) / Double(target - 1) * Double(stops.count - 1)
                    let low = Int(position.rounded(.down)), high = min(stops.count - 1, low + 1)
                    return GoveeSegmentColor.interpolate(stops[low], stops[high], fraction: position - Double(low))
                }
            } else {
                painted = Array(repeating: stops[0], count: target)
            }
        }
        return painted.map { $0.settingPower(true) }
    }

    /// Built-in paint jobs, mirroring the flavor of the Govee Home app's scene
    /// library while staying fully local.
    static let builtIns: [GoveeSegmentPreset] = [
        preset("Rainbow Flow", .smooth, [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x32ADE6, 0x5856D6, 0xAF52DE]),
        preset("Sunset Glow", .smooth, [0xFFD08A, 0xFF9A52, 0xFF5D6C, 0xC13584, 0x5B2A86]),
        preset("Ocean Drift", .smooth, [0x43E6D1, 0x27B9E8, 0x246BCE, 0x18438E]),
        preset("Aurora Veil", .smooth, [0x38E8D4, 0x6D7CFF, 0xB65CFF, 0x2EA9FF]),
        preset("Ember Coals", .smooth, [0x7D1D18, 0xD64724, 0xFF8A32, 0xFFC45B]),
        preset("Forest Canopy", .smooth, [0x294F35, 0x3E8E58, 0x79C267, 0xD2C66D]),
        preset("Fire & Ice", .smooth, [0xFF6A00, 0xFF9E45, 0xFFFFFF, 0x6FC3FF, 0x1B8CFF]),
        preset("Golden Hour", .smooth, [0xFFB45C, 0xFFD08A, 0xFFF0C2]),
        preset("Candy Cane", .repeating, [0xFF2D55, 0xFFFFFF]),
        preset("Fairy Dust", .repeating, [0xFFE57A, 0xB779FF, 0x8FD8FF]),
        preset("Holiday Cheer", .repeating, [0xD93A3A, 0x2CAB6F, 0xFFD43B]),
        preset("Grape Soda", .smooth, [0x8A35FF, 0xFF2E9A, 0xFF6FB5])
    ]

    private static func preset(_ name: String, _ fill: Fill, _ hexes: [UInt]) -> GoveeSegmentPreset {
        GoveeSegmentPreset(name: name, stops: hexes.map { GoveeSegmentColor(hex: $0) }, fill: fill)
    }
}
