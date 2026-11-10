import SwiftUI
import Foundation

// MARK: - Look Composer draft
//
// The per-fixture table in the Polar Look Composer edits one row per light:
// whether it is in the Look, the colour it holds and its level. Rows are
// plain values, so the table, the stage preview and Save all read the same
// draft, and the rules below are unit-tested without a window.

struct LookDraftRow: Identifiable, Equatable {
    let id: String          // LightDevice.id
    var included: Bool
    var rgb: UInt32         // 0xRRGGBB
    var level: Double       // 0.01...1

    var color: Color {
        Color(.sRGB,
              red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255,
              opacity: 1)
    }

    var hex: String { String(format: "#%06X", rgb) }
}

enum LookDraftBuilder {
    static let minimumLevel = 0.01

    /// Packs 0–1 components as 0xRRGGBB.
    static func rgb(red: Double, green: Double, blue: Double) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v.isFinite ? v : 0, 0), 1) * 255).rounded()) }
        return (byte(red) << 16) | (byte(green) << 8) | byte(blue)
    }

    static func rgb(hue: Double, saturation: Double) -> UInt32 {
        let h = (hue.isFinite ? hue - floor(hue) : 0) * 6
        let s = min(max(saturation.isFinite ? saturation : 0, 0), 1)
        let sector = Int(h) % 6
        let f = h - floor(h)
        let p = 1 - s, q = 1 - s * f, t = 1 - s * (1 - f)
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (1, t, p)
        case 1: (r, g, b) = (q, 1, p)
        case 2: (r, g, b) = (p, 1, t)
        case 3: (r, g, b) = (p, q, 1)
        case 4: (r, g, b) = (t, p, 1)
        default: (r, g, b) = (1, p, q)
        }
        return rgb(red: r, green: g, blue: b)
    }

    /// Hue and saturation (0–1) of a packed colour, for `DeviceSnapshot`.
    static func hueSaturation(_ rgb: UInt32) -> (hue: Double, saturation: Double) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        guard maxV > 0, delta > 0 else { return (0, 0) }
        var hue: Double
        if maxV == r { hue = (g - b) / delta }
        else if maxV == g { hue = 2 + (b - r) / delta }
        else { hue = 4 + (r - g) / delta }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxV)
    }

    /// Rows for an existing Look: lights it covers are included with their
    /// saved colour and level; the rest start excluded at their live colour.
    static func rows(editing look: LightingScene, lights: [LightDevice]) -> [LookDraftRow] {
        lights.map { light in
            if let snap = look.snapshots[light.id] {
                return LookDraftRow(id: light.id, included: true,
                                    rgb: rgb(hue: snap.hue, saturation: snap.saturation),
                                    level: max(minimumLevel, snap.isOn ? snap.brightness : minimumLevel))
            }
            let c = light.color.rgbComponents
            return LookDraftRow(id: light.id, included: false,
                                rgb: rgb(red: c.r, green: c.g, blue: c.b),
                                level: max(minimumLevel, light.brightness))
        }
    }

    /// Rows seeded from a palette: colours cycle through the lights in room
    /// order. With a selection, only selected lights start included.
    static func rows(palette colors: [UInt32], level: Double, lights: [LightDevice],
                     selection: Set<String>) -> [LookDraftRow] {
        lights.enumerated().map { index, light in
            LookDraftRow(id: light.id,
                         included: selection.isEmpty || selection.contains(light.id),
                         rgb: colors.isEmpty ? 0xFFFFFF : colors[index % colors.count],
                         level: max(minimumLevel, min(1, level)))
        }
    }

    /// Re-colours rows from a palette, keeping each row's include and level.
    static func repaint(_ rows: [LookDraftRow], palette colors: [UInt32]) -> [LookDraftRow] {
        guard !colors.isEmpty else { return rows }
        var paletteIndex = 0
        return rows.map { row in
            var copy = row
            if row.included {
                copy.rgb = colors[paletteIndex % colors.count]
                paletteIndex += 1
            }
            return copy
        }
    }

    /// Snapshots for the included rows.
    ///
    /// When editing an existing Look:
    /// - a row left exactly as it was keeps its original snapshot, so a
    ///   segment, matrix or panel layout is not flattened to one colour;
    /// - a row whose colour is unchanged but whose level changed keeps the
    ///   original spatial payload and Kelvin, with the new level applied;
    /// - fixtures the Look covers that have no row at all (not discovered,
    ///   or no longer in a room) keep their saved snapshot untouched.
    /// A row the user explicitly excluded is dropped.
    static func snapshots(_ rows: [LookDraftRow], kelvins: [String: Int],
                          original: LightingScene? = nil,
                          originalRows: [LookDraftRow] = []) -> [String: DeviceSnapshot] {
        let before = Dictionary(originalRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: DeviceSnapshot] = [:]
        for row in rows where row.included {
            if let original, let kept = original.snapshots[row.id], let opening = before[row.id] {
                if opening == row {
                    result[row.id] = kept
                    continue
                }
                if opening.rgb == row.rgb {
                    var adjusted = kept
                    adjusted.isOn = true
                    adjusted.brightness = max(minimumLevel, min(1, row.level))
                    // Per-zone LIFX layouts carry brightness in every zone and
                    // are applied without a master level, so the new level is
                    // scaled into the zones, keeping their relative levels.
                    if let matrix = kept.matrix {
                        adjusted.matrix = scaledMatrix(matrix, from: opening.level, to: adjusted.brightness)
                    }
                    result[row.id] = adjusted
                    continue
                }
            }
            let hs = hueSaturation(row.rgb)
            result[row.id] = DeviceSnapshot(isOn: true,
                                            brightness: max(minimumLevel, min(1, row.level)),
                                            hue: hs.hue, saturation: hs.saturation,
                                            kelvin: kelvins[row.id] ?? 3500)
        }
        if let original {
            let rowIDs = Set(rows.map(\.id))
            for (id, snap) in original.snapshots where !rowIDs.contains(id) {
                result[id] = snap
            }
        }
        return result
    }

    // MARK: Per-zone level

    /// Scales every used zone of a LIFX matrix (Luna's 26 zones, Tiles,
    /// Candles) by `newLevel / oldLevel`, so a level-only edit changes how
    /// bright the layout is without changing its shape:
    /// - zones at zero stay at zero (they are dark by design);
    /// - the factor is capped so the brightest zone reaches at most 100 %,
    ///   which keeps every zone's level relative to the others;
    /// - Set64 always carries 64 values, but only the first `width × height`
    ///   are the fixture's; the rest belong to the firmware and are kept.
    static func scaledMatrix(_ matrix: LIFXMatrixState, from oldLevel: Double, to newLevel: Double) -> LIFXMatrixState {
        let used = min(matrix.colors.count, max(0, matrix.width * matrix.height))
        guard used > 0, oldLevel.isFinite, newLevel.isFinite else { return matrix }
        var factor = max(0, newLevel) / max(minimumLevel, oldLevel)
        let brightest = matrix.colors.prefix(used).map(\.brightness).max() ?? 0
        guard brightest > 0 else { return matrix }
        factor = min(factor, 65_535 / Double(brightest))
        var scaled = matrix
        for index in 0..<used {
            let current = Double(matrix.colors[index].brightness)
            guard current > 0 else { continue }
            let next = max(1, min(65_535, (current * factor).rounded()))
            scaled.colors[index].brightness = UInt16(next)
        }
        return scaled
    }

    // MARK: Scope

    /// The composer keeps one row per light in every room for the whole
    /// session; the This room / All rooms switch only filters what the
    /// table shows, so switching never drops or resets a row.
    static func isVisible(_ row: LookDraftRow, allRooms: Bool, roomLightIDs: Set<String>) -> Bool {
        allRooms || roomLightIDs.contains(row.id)
    }

    /// Included rows the This room view is hiding (they still save).
    static func hiddenIncludedCount(_ rows: [LookDraftRow], allRooms: Bool, roomLightIDs: Set<String>) -> Int {
        rows.filter { $0.included && !isVisible($0, allRooms: allRooms, roomLightIDs: roomLightIDs) }.count
    }

    /// A new Look starts with only the open room's lights included (or the
    /// selection within it); other rooms' rows exist but start excluded.
    static func limitIncluded(_ rows: [LookDraftRow], to ids: Set<String>) -> [LookDraftRow] {
        rows.map { row in
            var copy = row
            if !ids.contains(row.id) { copy.included = false }
            return copy
        }
    }

    /// "Evening copy", "Evening copy 2", … never colliding with `existing`.
    static func copyName(for name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let base = "\(name) copy"
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Sidebar Looks

    /// The room a sidebar Look applies to: the open room when the Look
    /// covers any of its fixtures, otherwise the room holding most of the
    /// Look's fixtures (sidebar order breaks ties). Nil when no room has
    /// one of its fixtures.
    static func room(for look: LightingScene, rooms: [Room], preferring currentID: UUID?) -> Room? {
        let lookIDs = Set(look.snapshots.keys)
        if let current = rooms.first(where: { $0.id == currentID }),
           !lookIDs.isDisjoint(with: current.lightIDs) {
            return current
        }
        var best: (room: Room, count: Int)? = nil
        for room in rooms {
            let count = lookIDs.intersection(room.lightIDs).count
            if count > 0, count > (best?.count ?? 0) { best = (room, count) }
        }
        return best?.room
    }
}
