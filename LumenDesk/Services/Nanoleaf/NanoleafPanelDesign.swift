import Foundation

// MARK: - Colour

/// An 8-bit colour as it goes on the wire.
struct NanoleafRGB: Equatable, Hashable, Codable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    static let black = NanoleafRGB(red: 0, green: 0, blue: 0)

    var hexString: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Accepts `#RRGGBB` or `RRGGBB`, any case, surrounding space ignored.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
    }
}

/// One panel's colour in a LumenDesk design: chroma plus the panel's own
/// intensity.
///
/// Intensity is the panel's level inside the design and is folded into the
/// RGB sent for that panel, once, here. The controller's master brightness is
/// a separate device setting that scales every panel on top of this; it is
/// never folded in, so editing a panel cannot move the master level and the
/// master level cannot rewrite a design. Intensity 0 is black output. Shapes
/// panels have no individual power, so a dark panel is exactly that: black.
struct NanoleafPanelColor: Equatable, Hashable, Codable {
    let hue: Double
    let saturation: Double
    let intensity: Double

    init(hue: Double, saturation: Double, intensity: Double) {
        self.hue = hue.isFinite ? hue - floor(hue) : 0
        self.saturation = saturation.isFinite ? min(1, max(0, saturation)) : 0
        self.intensity = intensity.isFinite ? min(1, max(0, intensity)) : 0
    }

    /// The exact inverse of `rgb`: the colour whose output is this RGB.
    /// A typed hex value therefore lands on the wire unchanged.
    init(rgb: NanoleafRGB) {
        let r = Double(rgb.red) / 255, g = Double(rgb.green) / 255, b = Double(rgb.blue) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low
        var hue = 0.0
        if delta > 0 {
            if high == r { hue = (g - b) / delta }
            else if high == g { hue = 2 + (b - r) / delta }
            else { hue = 4 + (r - g) / delta }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        self.init(hue: hue, saturation: high == 0 ? 0 : delta / high, intensity: high)
    }

    init?(hex: String) {
        guard let rgb = NanoleafRGB(hex: hex) else { return nil }
        self.init(rgb: rgb)
    }

    static let white = NanoleafPanelColor(hue: 0, saturation: 0, intensity: 1)
    static let black = NanoleafPanelColor(hue: 0, saturation: 0, intensity: 0)

    /// What the panel is sent. The only place intensity scales output.
    var rgb: NanoleafRGB { Self.rgb(hue: hue, saturation: saturation, value: intensity) }

    /// The same chroma at full intensity, for swatches and pickers.
    var chroma: NanoleafRGB { Self.rgb(hue: hue, saturation: saturation, value: 1) }

    var hexString: String { rgb.hexString }
    var isBlack: Bool { rgb == .black }

    func settingIntensity(_ value: Double) -> NanoleafPanelColor {
        NanoleafPanelColor(hue: hue, saturation: saturation, intensity: value)
    }

    /// This colour's chroma at another colour's intensity.
    func keepingIntensity(of other: NanoleafPanelColor) -> NanoleafPanelColor {
        NanoleafPanelColor(hue: hue, saturation: saturation, intensity: other.intensity)
    }

    private static func rgb(hue: Double, saturation: Double, value: Double) -> NanoleafRGB {
        let sector = hue * 6
        let index = Int(floor(sector)) % 6
        let fraction = sector - floor(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * fraction)
        let t = value * (1 - saturation * (1 - fraction))
        let (r, g, b): (Double, Double, Double)
        switch index {
        case 0: (r, g, b) = (value, t, p)
        case 1: (r, g, b) = (q, value, p)
        case 2: (r, g, b) = (p, value, t)
        case 3: (r, g, b) = (p, q, value)
        case 4: (r, g, b) = (t, p, value)
        default: (r, g, b) = (value, p, q)
        }
        func byte(_ channel: Double) -> UInt8 { UInt8(min(255, max(0, (channel * 255).rounded()))) }
        return NanoleafRGB(red: byte(r), green: byte(g), blue: byte(b))
    }
}

// MARK: - Design

/// Which panels a design covers, measured against the arrangement that is on
/// the wall now. Designs are keyed by panel ID and never remapped by list
/// position, so a panel that left the wall stays "missing" until the user
/// deliberately moves its colour to another panel.
struct NanoleafDesignReconciliation: Equatable {
    /// In the design and on the wall.
    let covered: [Int]
    /// In the design, no longer reported by the controller.
    let missing: [Int]
    /// On the wall, not in the design. Sent black when the design is shown.
    let uncovered: [Int]

    var isExact: Bool { missing.isEmpty && uncovered.isEmpty }

    var summary: String? {
        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("\(missing.count) panel\(missing.count == 1 ? " is" : "s are") no longer on the wall")
        }
        if !uncovered.isEmpty {
            parts.append("\(uncovered.count) panel\(uncovered.count == 1 ? " isn't" : "s aren't") in this design and will show dark")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }
}

/// A LumenDesk-authored layout for one Shapes controller: a colour per
/// panel ID. It holds what the user intends; whether the wall is showing it
/// is tracked separately by the caller.
struct NanoleafPanelDesign: Equatable, Codable {
    private(set) var colors: [Int: NanoleafPanelColor]

    init(colors: [Int: NanoleafPanelColor] = [:]) {
        self.colors = colors.filter { $0.key >= 0 && $0.key <= Int(UInt16.max) }
    }

    static func uniform<S: Sequence>(_ color: NanoleafPanelColor, panelIDs: S) -> NanoleafPanelDesign where S.Element == Int {
        NanoleafPanelDesign(colors: Dictionary(panelIDs.map { ($0, color) }, uniquingKeysWith: { first, _ in first }))
    }

    var isEmpty: Bool { colors.isEmpty }
    var panelIDs: [Int] { colors.keys.sorted() }

    subscript(panelID: Int) -> NanoleafPanelColor? { colors[panelID] }

    /// Sets chroma and intensity on exactly these panels. Every other panel
    /// is untouched.
    mutating func paint(_ color: NanoleafPanelColor, panels: Set<Int>) {
        for id in panels where id >= 0 && id <= Int(UInt16.max) { colors[id] = color }
    }

    /// Replaces chroma on these panels and keeps each one's own intensity,
    /// so recolouring a dimmed group does not relight it.
    mutating func recolor(_ color: NanoleafPanelColor, panels: Set<Int>) {
        for id in panels where id >= 0 && id <= Int(UInt16.max) {
            colors[id] = color.keepingIntensity(of: colors[id] ?? color)
        }
    }

    mutating func setIntensity(_ intensity: Double, panels: Set<Int>) {
        for id in panels {
            guard let current = colors[id] else { continue }
            colors[id] = current.settingIntensity(intensity)
        }
    }

    /// Moves one panel's colour to another ID: the deliberate step after a
    /// panel was replaced and came back with a new ID.
    mutating func remap(from oldID: Int, to newID: Int) {
        guard let color = colors.removeValue(forKey: oldID), newID >= 0, newID <= Int(UInt16.max) else { return }
        colors[newID] = color
    }

    mutating func removePanels(_ ids: Set<Int>) {
        for id in ids { colors.removeValue(forKey: id) }
    }

    /// The chroma covering the most lit panels, for places that show a light
    /// as one swatch. Ties go to the brighter group, then the lower hex, so
    /// the answer never depends on dictionary order. Nil when nothing is lit.
    var representativeChroma: NanoleafRGB? {
        var groups: [NanoleafRGB: (count: Int, intensity: Double)] = [:]
        for color in colors.values where !color.isBlack {
            let entry = groups[color.chroma] ?? (0, 0)
            groups[color.chroma] = (entry.count + 1, max(entry.intensity, color.intensity))
        }
        return groups.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if a.value.intensity != b.value.intensity { return a.value.intensity < b.value.intensity }
            return a.key.hexString > b.key.hexString
        }?.key
    }

    /// True when at least one light panel on the wall would be lit.
    func lightsAnyPanel(of layout: NanoleafLayout) -> Bool {
        layout.paintablePanels.contains { colors[$0.panelID].map { !$0.isBlack } ?? false }
    }

    func reconciliation(against layout: NanoleafLayout) -> NanoleafDesignReconciliation {
        let onWall = layout.paintableIDs
        let designed = Set(colors.keys)
        return NanoleafDesignReconciliation(
            covered: designed.intersection(onWall).sorted(),
            missing: designed.subtracting(onWall).sorted(),
            uncovered: onWall.subtracting(designed).sorted()
        )
    }

    /// One frame per light panel on the wall, in ascending ID order. Panels
    /// the design does not cover go out black, never a guessed colour, and
    /// panels the wall no longer has are left out. Nothing that is not a
    /// Shapes light panel is ever addressed.
    func frames(for layout: NanoleafLayout, transition: Int) -> [NanoleafPanelFrame] {
        layout.paintablePanels.map { panel in
            NanoleafPanelFrame(panelID: panel.panelID,
                               rgb: colors[panel.panelID]?.rgb ?? .black,
                               transition: transition)
        }
    }

    // A readable archive: one object per panel rather than the alternating
    // key/value array JSONEncoder writes for integer-keyed dictionaries.
    private enum CodingKeys: String, CodingKey { case panels }

    private struct Entry: Codable {
        let id: Int
        let hue: Double
        let saturation: Double
        let intensity: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Strict per entry: a design that silently lost a panel would show
        // that panel dark and look like a deliberate choice. A damaged design
        // fails as a whole and the caller keeps its other designs.
        let entries = try container.decode([Entry].self, forKey: .panels)
        var colors: [Int: NanoleafPanelColor] = [:]
        for entry in entries {
            guard entry.id >= 0, entry.id <= Int(UInt16.max), colors[entry.id] == nil,
                  entry.hue.isFinite, entry.saturation.isFinite, entry.intensity.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .panels, in: container,
                                                       debugDescription: "Unreadable panel entry")
            }
            colors[entry.id] = NanoleafPanelColor(hue: entry.hue, saturation: entry.saturation, intensity: entry.intensity)
        }
        self.colors = colors
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colors.keys.sorted().map { id -> Entry in
            let color = colors[id]!
            return Entry(id: id, hue: color.hue, saturation: color.saturation, intensity: color.intensity)
        }, forKey: .panels)
    }
}

// MARK: - Wire formats

/// What one panel is told to do in a single command or stream frame.
struct NanoleafPanelFrame: Equatable, Hashable {
    let panelID: Int
    let rgb: NanoleafRGB
    /// Fade time in tenths of a second, the unit the protocol counts in.
    let transition: Int
}

enum NanoleafAnimDataError: Error, Equatable {
    case malformed(String)
}

/// The panel-resolved text format used by `static` and `custom` effects:
/// `numPanels; panelId; numFrames; R G B W T; ...`, space separated.
enum NanoleafAnimData {
    struct Keyframe: Equatable {
        let rgb: NanoleafRGB
        let white: Int
        /// Tenths of a second; -1 marks an instant start frame.
        let transition: Int
    }

    /// One frame per panel: the static form. W is always 0 because the
    /// firmware ignores it and drives the white LED from its own calibration.
    static func staticString(_ frames: [NanoleafPanelFrame]) -> String {
        var parts = [String(frames.count)]
        parts.reserveCapacity(1 + frames.count * 7)
        for frame in frames {
            parts.append(String(frame.panelID))
            parts.append("1")
            parts.append(String(frame.rgb.red))
            parts.append(String(frame.rgb.green))
            parts.append(String(frame.rgb.blue))
            parts.append("0")
            parts.append(String(max(0, frame.transition)))
        }
        return parts.joined(separator: " ")
    }

    /// Reads the format back, strictly: a count that disagrees with the
    /// content, a channel out of range, or a duplicated panel is an error.
    static func parse(_ text: String) throws -> [Int: [Keyframe]] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        var cursor = 0
        func next(_ what: String) throws -> Int {
            guard cursor < tokens.count, let value = Int(tokens[cursor]) else {
                throw NanoleafAnimDataError.malformed("expected \(what)")
            }
            cursor += 1
            return value
        }
        let panelCount = try next("a panel count")
        guard panelCount >= 0, panelCount <= Int(UInt16.max) else { throw NanoleafAnimDataError.malformed("impossible panel count") }
        var result: [Int: [Keyframe]] = [:]
        for _ in 0..<panelCount {
            let id = try next("a panel ID")
            let frameCount = try next("a frame count")
            guard id >= 0, id <= Int(UInt16.max), result[id] == nil else {
                throw NanoleafAnimDataError.malformed("panel \(id) is repeated or out of range")
            }
            guard frameCount >= 1, frameCount <= 10_000 else {
                throw NanoleafAnimDataError.malformed("panel \(id) has an impossible frame count")
            }
            var frames: [Keyframe] = []
            for _ in 0..<frameCount {
                let r = try next("red"), g = try next("green"), b = try next("blue")
                let w = try next("white"), t = try next("a transition")
                guard (0...255).contains(r), (0...255).contains(g), (0...255).contains(b), (0...255).contains(w), t >= -1 else {
                    throw NanoleafAnimDataError.malformed("panel \(id) has a channel out of range")
                }
                frames.append(Keyframe(rgb: NanoleafRGB(red: UInt8(r), green: UInt8(g), blue: UInt8(b)),
                                       white: w, transition: t))
            }
            result[id] = frames
        }
        guard cursor == tokens.count else { throw NanoleafAnimDataError.malformed("unexpected trailing values") }
        return result
    }

    /// Where each panel of a static or custom effect comes to rest: its last
    /// keyframe. For a one-frame static effect this is exactly what the wall
    /// shows, which is what makes a stored static scene importable.
    static func settledColors(_ text: String) throws -> [Int: NanoleafRGB] {
        try parse(text).compactMapValues { $0.last?.rgb }
    }
}

/// External control ("extControl") version 2, the only version Shapes
/// accept: `nPanels`, then per panel `panelId R G B W transition`, with the
/// count, ID and transition as big-endian UInt16. Frames go by UDP to port
/// 60222 on the controller once the mode is activated over HTTP.
enum NanoleafStreamPacket {
    static let defaultPort: UInt16 = 60222
    /// Nanoleaf asks external controllers never to stream faster than 10 Hz;
    /// fades of 100 ms or more are smoothed by the panels themselves.
    static let minimumFrameInterval: TimeInterval = 0.1

    static func encode(_ frames: [NanoleafPanelFrame]) -> Data {
        let frames = frames.prefix(Int(UInt16.max))
        var data = Data()
        data.reserveCapacity(2 + frames.count * 8)
        appendUInt16(UInt16(frames.count), to: &data)
        for frame in frames {
            appendUInt16(UInt16(clamping: frame.panelID), to: &data)
            data.append(frame.rgb.red)
            data.append(frame.rgb.green)
            data.append(frame.rgb.blue)
            data.append(0)
            appendUInt16(UInt16(clamping: max(0, frame.transition)), to: &data)
        }
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }
}
