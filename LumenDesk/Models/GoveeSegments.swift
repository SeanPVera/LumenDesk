import Foundation
import SwiftUI

// MARK: - Segment capability catalog

/// Physical layout of a segmented Govee light. Drives how the Segment Studio
/// draws the device (continuous COB bar vs. bulbs on a wire) and which
/// controls make sense (only blended strips expose the gradient toggle).
enum GoveeSegmentLayout: String, Codable {
    case cobStrip      // continuous chip-on-board strip; colors can blend
    case stringLights  // discrete bulbs or clusters along a wire
    case neonRope      // flexible neon tube; behaves like a fine-grained strip
    case generic       // unrecognized RGBIC device

    var displayName: String {
        switch self {
        case .cobStrip: return "COB strip"
        case .stringLights: return "String lights"
        case .neonRope: return "Neon rope"
        case .generic: return "RGBIC light"
        }
    }

    var icon: String {
        switch self {
        case .cobStrip: return "rectangle.split.3x1.fill"
        case .stringLights: return "party.popper.fill"
        case .neonRope: return "scribble.variable"
        case .generic: return "lightbulb.led.fill"
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
        func add(_ sku: String, _ layout: GoveeSegmentLayout, _ count: Int, _ gradient: Bool) {
            rows[sku] = GoveeSegmentProfile(layout: layout, defaultSegmentCount: count, supportsGradient: gradient, recognized: true)
        }
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
        // String / curtain lights
        add("H70C1", .stringLights, 20, false)
        add("H70C2", .stringLights, 20, false)
        add("H70C4", .stringLights, 20, false)
        add("H70B1", .stringLights, 20, false)
        add("H7021", .stringLights, 12, false)
        add("H7028", .stringLights, 12, false)
        return rows
    }()

    private static let prefixMatches: [(prefix: String, profile: GoveeSegmentProfile)] = {
        var rows: [(prefix: String, profile: GoveeSegmentProfile)] = []
        func add(_ prefix: String, _ layout: GoveeSegmentLayout, _ count: Int, _ gradient: Bool) {
            rows.append((prefix, GoveeSegmentProfile(layout: layout, defaultSegmentCount: count, supportsGradient: gradient, recognized: true)))
        }
        add("H619", .cobStrip, 15, true)
        add("H61C", .cobStrip, 15, true)
        add("H61E", .cobStrip, 15, true)
        add("H61A", .neonRope, 20, true)
        add("H61B", .neonRope, 20, true)
        add("H61D", .neonRope, 20, true)
        add("H70C", .stringLights, 20, false)
        add("H70B", .stringLights, 20, false)
        add("H702", .stringLights, 12, false)
        return rows
    }()

    /// Fallback shown when the user opens the studio for an unrecognized SKU.
    static let generic = GoveeSegmentProfile(layout: .generic, defaultSegmentCount: 15, supportsGradient: true, recognized: false)
}

// MARK: - Per-segment state

/// One segment's color and its individual brightness (the Govee Home app
/// allows both per segment).
struct GoveeSegmentColor: Equatable {
    var red: Double        // 0…1
    var green: Double      // 0…1
    var blue: Double       // 0…1
    var brightness: Double // 0…1

    init(red: Double, green: Double, blue: Double, brightness: Double = 1.0) {
        self.red = max(0, min(1, red))
        self.green = max(0, min(1, green))
        self.blue = max(0, min(1, blue))
        self.brightness = max(0, min(1, brightness))
    }

    init(color: Color, brightness: Double = 1.0) {
        let rgb = color.rgbComponents
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b, brightness: brightness)
    }

    init(hex: UInt, brightness: Double = 1.0) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  brightness: brightness)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    /// Color with the segment's own brightness folded in, for previews.
    var litColor: Color {
        Color(red: red * max(0.05, brightness),
              green: green * max(0.05, brightness),
              blue: blue * max(0.05, brightness))
    }
    var rgb255: (r: Int, g: Int, b: Int) {
        (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    /// Grouping key so identical colors share one LAN packet.
    var packetKey: String {
        let c = rgb255
        return "\(c.r):\(c.g):\(c.b)"
    }
    var brightnessPercent: Int { max(1, min(100, Int((brightness * 100).rounded()))) }

    static func interpolate(_ from: GoveeSegmentColor, _ to: GoveeSegmentColor, fraction: Double) -> GoveeSegmentColor {
        let t = max(0, min(1, fraction))
        return GoveeSegmentColor(red: from.red + (to.red - from.red) * t,
                                 green: from.green + (to.green - from.green) * t,
                                 blue: from.blue + (to.blue - from.blue) * t,
                                 brightness: from.brightness + (to.brightness - from.brightness) * t)
    }
}

extension GoveeSegmentColor: Codable {
    enum CodingKeys: String, CodingKey { case red, green, blue, brightness }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let red = try c.decode(Double.self, forKey: .red)
        let green = try c.decode(Double.self, forKey: .green)
        let blue = try c.decode(Double.self, forKey: .blue)
        let brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? 1.0
        self.init(red: red, green: green, blue: blue, brightness: brightness)
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
    var blendedColor: Color {
        guard !colors.isEmpty else { return .white }
        let n = Double(colors.count)
        return Color(red: colors.map(\.red).reduce(0, +) / n,
                     green: colors.map(\.green).reduce(0, +) / n,
                     blue: colors.map(\.blue).reduce(0, +) / n)
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

    /// Renders the preset onto `count` segments.
    func colors(for count: Int) -> [GoveeSegmentColor] {
        let target = max(1, count)
        guard !stops.isEmpty else { return Array(repeating: GoveeSegmentColor(hex: 0xFFFFFF), count: target) }
        switch fill {
        case .repeating:
            return (0..<target).map { stops[$0 % stops.count] }
        case .smooth:
            guard stops.count > 1, target > 1 else { return Array(repeating: stops[0], count: target) }
            return (0..<target).map { index in
                let position = Double(index) / Double(target - 1) * Double(stops.count - 1)
                let low = Int(position.rounded(.down)), high = min(stops.count - 1, low + 1)
                return GoveeSegmentColor.interpolate(stops[low], stops[high], fraction: position - Double(low))
            }
        }
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
