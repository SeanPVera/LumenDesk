import Foundation

// MARK: - Shape types

/// What one `positionData` entry is, read from its `shapeType` code.
///
/// Codes and side lengths come from Nanoleaf's OpenAPI layout table (section
/// 3.3). The table is authoritative for geometry because the layout's own
/// `sideLength` field is deprecated: it cannot describe a wall that mixes
/// shapes, and firmware 5.0 and later is documented to report 0. One NL42 on
/// firmware 9.2 was observed reporting 27 while its mini triangles sat 38.1
/// units apart, which is the spacing a 67-unit side produces. Geometry never
/// reads that field.
enum NanoleafShapeKind: Equatable, Hashable {
    case hexagon
    case triangle
    case miniTriangle
    /// The Shapes controller module. It appears in the layout (usually as
    /// panel ID 0) but has no addressable light.
    case controller
    /// Hardware Nanoleaf lists that never emits light: the Rhythm module,
    /// power supplies, Lines connectors, controller caps, power connectors.
    case accessory(code: Int)
    /// A light-emitting panel from another product family (Light Panels,
    /// Canvas, Elements, Lines, 4D, Skylight). It is real, but it is not a
    /// Shapes panel, so it is shown for reference and never sent colour.
    case otherFamily(code: Int)
    /// A code Nanoleaf's table does not list.
    case unknown(code: Int)
    /// The entry carried no `shapeType` at all.
    case unspecified

    init(code: Int?) {
        guard let code else { self = .unspecified; return }
        switch code {
        case 7: self = .hexagon
        case 8: self = .triangle
        case 9: self = .miniTriangle
        case 12: self = .controller
        case 1, 5, 16, 19, 20: self = .accessory(code: code)
        case 0, 2, 3, 4, 14, 15, 17, 18, 29, 30, 31, 32: self = .otherFamily(code: code)
        default: self = .unknown(code: code)
        }
    }

    /// Only these three are Shapes light panels, and only they are ever
    /// addressed by panel-resolved commands.
    var isPaintable: Bool {
        switch self {
        case .hexagon, .triangle, .miniTriangle: return true
        default: return false
        }
    }

    /// Edge length in layout units, from Nanoleaf's table.
    var sideLength: Double? {
        switch self {
        case .hexagon: return 67
        case .triangle: return 134
        case .miniTriangle: return 67
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .hexagon: return "Hexagon"
        case .triangle: return "Triangle"
        case .miniTriangle: return "Mini triangle"
        case .controller: return "Controller"
        case .accessory(let code):
            switch code {
            case 1: return "Rhythm module"
            case 5: return "Power supply"
            case 16: return "Lines connector"
            case 19: return "Controller cap"
            case 20: return "Power connector"
            default: return "Accessory \(code)"
            }
        case .otherFamily(let code): return "Non-Shapes panel (type \(code))"
        case .unknown(let code): return "Unknown part (type \(code))"
        case .unspecified: return "Unidentified part"
        }
    }
}

// MARK: - Panels and layout

/// One entry of the controller's `positionData`, exactly as reported.
///
/// Identity is the controller's serial plus `panelID`. The entry's position
/// in the response array is never used as an identity: controllers do not
/// promise an order, and a panel added to the wall can appear anywhere in it.
struct NanoleafPanel: Equatable, Hashable, Codable, Identifiable {
    let panelID: Int
    /// Centroid in the controller's layout space, where y points up.
    let x: Double
    let y: Double
    /// The panel's own rotation in degrees, counter-clockwise, as reported.
    /// Physically fixed by how the panel is mounted; software cannot change it.
    let orientation: Double
    /// The raw `shapeType`, kept so an unknown code survives a round trip.
    let shapeCode: Int?

    var id: Int { panelID }
    var kind: NanoleafShapeKind { NanoleafShapeKind(code: shapeCode) }
    var isPaintable: Bool { kind.isPaintable }
}

/// The arrangement as the controller reports it. Raw topology only: rotation
/// for display, room placement, zoom and selection all live elsewhere, so a
/// change of orientation can never rewrite a panel's identity or position.
struct NanoleafLayout: Equatable, Codable {
    /// Every entry, in the order the controller listed it.
    let panels: [NanoleafPanel]
    /// `numPanels`. For Shapes it counts the controller entry too.
    let reportedPanelCount: Int?
    /// The deprecated `sideLength` field, kept only for diagnostics.
    let legacySideLength: Int?

    init(panels: [NanoleafPanel], reportedPanelCount: Int? = nil, legacySideLength: Int? = nil) {
        self.panels = panels
        self.reportedPanelCount = reportedPanelCount
        self.legacySideLength = legacySideLength
    }

    /// Light panels in ascending ID order: a stable order for lists, tests
    /// and encoders that does not depend on how the response was sorted.
    var paintablePanels: [NanoleafPanel] {
        panels.filter(\.isPaintable).sorted { $0.panelID < $1.panelID }
    }

    var paintableIDs: Set<Int> { Set(panels.lazy.filter(\.isPaintable).map(\.panelID)) }

    /// Entries that are drawn for reference but never addressed.
    var referenceEntries: [NanoleafPanel] { panels.filter { !$0.isPaintable } }

    func panel(withID id: Int) -> NanoleafPanel? { panels.first { $0.panelID == id } }

    /// Parts the integration will not draw as Shapes panels, excluding the
    /// controller, which is expected on every Shapes wall.
    var unsupportedEntries: [NanoleafPanel] {
        panels.filter { entry in
            switch entry.kind {
            case .otherFamily, .unknown, .unspecified: return true
            default: return false
            }
        }
    }

    /// `numPanels` disagreed with the entries actually described, which
    /// usually means the response was cut short or the wall changed while it
    /// was being read.
    var isPossiblyIncomplete: Bool {
        guard let reportedPanelCount else { return false }
        return reportedPanelCount != panels.count
    }

    var shapeSummary: String {
        let counts = Dictionary(grouping: paintablePanels, by: { $0.kind.displayName })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
        guard !counts.isEmpty else { return "No light panels" }
        return counts.map { "\($0.count) \($0.name.lowercased())\($0.count == 1 ? "" : "s")" }
            .joined(separator: ", ")
    }
}

// MARK: - Orientation

/// The arrangement's global orientation, which Nanoleaf defines as the
/// user's preferred rotation for viewing the layout. It never changes the
/// raw panel data.
enum NanoleafOrientationReport: Equatable, Codable {
    case reported(value: Int, minimum: Int, maximum: Int)
    /// The response had no `globalOrientation` at all.
    case notReported
    /// It was present but could not be read as a number.
    case unreadable

    /// Degrees in 0..<360, or nil when the controller did not say.
    var degrees: Int? {
        guard case .reported(let value, _, _) = self else { return nil }
        return NanoleafOrientation.normalized(value)
    }

    var range: ClosedRange<Int> {
        guard case .reported(_, let minimum, let maximum) = self, minimum <= maximum else { return 0...360 }
        return minimum...maximum
    }
}

enum NanoleafOrientation {
    /// Folds any whole-degree value into 0..<360. The controller reports 360
    /// for the same view as 0.
    static func normalized(_ degrees: Int) -> Int {
        let remainder = degrees % 360
        return remainder < 0 ? remainder + 360 : remainder
    }

    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    /// The value to write for a requested view, clamped into what the
    /// controller advertised it accepts.
    static func writableValue(_ degrees: Int, range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, normalized(degrees)))
    }
}

/// Topology plus orientation, as last read from the controller.
struct NanoleafArrangement: Equatable, Codable {
    var layout: NanoleafLayout
    var orientation: NanoleafOrientationReport

    var globalOrientation: Int? { orientation.degrees }
}

// MARK: - Parsing

enum NanoleafTopologyProblem: Error, Equatable {
    /// The controller's response carried no layout. Different from a
    /// damaged one: nothing was misread, there was simply nothing to read.
    case notReported
    /// The layout was present but could not be trusted. The message names
    /// what was wrong without echoing any part of the request.
    case malformed(String)

    var summary: String {
        switch self {
        case .notReported: return "The controller did not report its panel layout."
        case .malformed(let detail): return "The controller reported a panel layout LumenDesk could not read: \(detail)."
        }
    }
}

/// Reads `panelLayout` out of a controller response.
///
/// Deliberately strict where tolerance would mislead. A tolerant decoder
/// that dropped an unreadable entry, or defaulted a missing coordinate to 0,
/// would hand the editor a plausible-looking wall that is not the one on the
/// user's wall, and a colour aimed at it would land on the wrong panel. So an
/// entry without an ID or a position, a duplicated ID, or an ID no command
/// can address rejects the whole layout, and callers keep the last layout
/// they trusted. Missing `shapeType` is the one tolerated gap: that entry is
/// kept, drawn as unidentified, and never painted.
enum NanoleafTopologyParser {
    static let maximumCoordinate = 100_000.0

    static func parse(_ data: Data) -> Result<NanoleafArrangement, NanoleafTopologyProblem> {
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).result
        } catch {
            return .failure(.malformed("the response was not a JSON object"))
        }
    }

    private struct Envelope: Decodable {
        let result: Result<NanoleafArrangement, NanoleafTopologyProblem>

        private enum Keys: String, CodingKey { case panelLayout }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard container.contains(.panelLayout) else {
                result = .failure(.notReported)
                return
            }
            do {
                let payload = try container.decode(PanelLayoutPayload.self, forKey: .panelLayout)
                result = payload.result
            } catch let problem as NanoleafTopologyProblem {
                result = .failure(problem)
            } catch {
                result = .failure(.malformed("panelLayout was not an object"))
            }
        }
    }

    private struct PanelLayoutPayload: Decodable {
        let result: Result<NanoleafArrangement, NanoleafTopologyProblem>

        private enum Keys: String, CodingKey { case layout, globalOrientation }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let orientation = Self.orientation(in: container)
            guard container.contains(.layout) else {
                result = .failure(.notReported)
                return
            }
            let layout: NanoleafLayout
            do {
                layout = try container.decode(LayoutPayload.self, forKey: .layout).layout
            } catch let problem as NanoleafTopologyProblem {
                result = .failure(problem)
                return
            } catch {
                result = .failure(.malformed("layout was not an object"))
                return
            }
            result = .success(NanoleafArrangement(layout: layout, orientation: orientation))
        }

        private static func orientation(in container: KeyedDecodingContainer<Keys>) -> NanoleafOrientationReport {
            guard container.contains(.globalOrientation) else { return .notReported }
            guard let payload = try? container.decode(RangedValue.self, forKey: .globalOrientation),
                  let value = payload.value else { return .unreadable }
            return .reported(value: value, minimum: payload.minimum ?? 0, maximum: payload.maximum ?? 360)
        }
    }

    /// `{value, max, min}` as the controller writes ranged values.
    private struct RangedValue: Decodable {
        let value: Int?
        let minimum: Int?
        let maximum: Int?

        private enum Keys: String, CodingKey { case value, min, max }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            value = try Self.whole(container, .value)
            minimum = try Self.whole(container, .min)
            maximum = try Self.whole(container, .max)
        }

        private static func whole(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) throws -> Int? {
            guard container.contains(key) else { return nil }
            let number = try container.decode(Double.self, forKey: key)
            guard number.isFinite, abs(number) < 1_000_000 else { throw NanoleafTopologyProblem.malformed("orientation was not a finite number") }
            return Int(number.rounded())
        }
    }

    private struct LayoutPayload: Decodable {
        let layout: NanoleafLayout

        private enum Keys: String, CodingKey { case numPanels, sideLength, positionData }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            guard container.contains(.positionData) else {
                throw NanoleafTopologyProblem.malformed("positionData is missing")
            }
            var entries: UnkeyedDecodingContainer
            do {
                entries = try container.nestedUnkeyedContainer(forKey: .positionData)
            } catch {
                throw NanoleafTopologyProblem.malformed("positionData is not a list")
            }
            var panels: [NanoleafPanel] = []
            var seen = Set<Int>()
            var index = 0
            while !entries.isAtEnd {
                let entry: EntryPayload
                do {
                    entry = try entries.decode(EntryPayload.self)
                } catch let problem as NanoleafTopologyProblem {
                    throw problem
                } catch {
                    throw NanoleafTopologyProblem.malformed("entry \(index + 1) is not a panel description")
                }
                guard seen.insert(entry.panel.panelID).inserted else {
                    throw NanoleafTopologyProblem.malformed("panel ID \(entry.panel.panelID) appears more than once")
                }
                panels.append(entry.panel)
                index += 1
            }
            // Informational only, so an odd value is ignored rather than fatal.
            let count: Double? = try? container.decodeIfPresent(Double.self, forKey: .numPanels)
            let side: Double? = try? container.decodeIfPresent(Double.self, forKey: .sideLength)
            layout = NanoleafLayout(
                panels: panels,
                reportedPanelCount: count.flatMap { $0.isFinite && abs($0) < 100_000 ? Int($0) : nil },
                legacySideLength: side.flatMap { $0.isFinite && abs($0) < 100_000 ? Int($0) : nil }
            )
        }
    }

    private struct EntryPayload: Decodable {
        let panel: NanoleafPanel

        private enum Keys: String, CodingKey { case panelId, x, y, o, shapeType }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let rawID = try Self.number(container, .panelId, field: "panel ID")
            // Stream packets carry the ID in two bytes; anything outside that
            // could never be addressed, so it cannot be a panel we trust.
            guard rawID == rawID.rounded(), rawID >= 0, rawID <= Double(UInt16.max) else {
                throw NanoleafTopologyProblem.malformed("a panel ID cannot be addressed")
            }
            let id = Int(rawID)
            let x = try Self.number(container, .x, field: "x position", panel: id)
            let y = try Self.number(container, .y, field: "y position", panel: id)
            let o = try Self.number(container, .o, field: "orientation", panel: id)
            guard abs(x) <= NanoleafTopologyParser.maximumCoordinate,
                  abs(y) <= NanoleafTopologyParser.maximumCoordinate else {
                throw NanoleafTopologyProblem.malformed("panel \(id) is positioned outside any plausible wall")
            }
            var shape: Int?
            if container.contains(.shapeType) {
                guard let code = try? container.decode(Double.self, forKey: .shapeType),
                      code.isFinite, code == code.rounded(), abs(code) < 10_000 else {
                    throw NanoleafTopologyProblem.malformed("panel \(id) has an unreadable shape type")
                }
                shape = Int(code)
            }
            panel = NanoleafPanel(panelID: id, x: x, y: y, orientation: o, shapeCode: shape)
        }

        private static func number(_ container: KeyedDecodingContainer<Keys>, _ key: Keys,
                                   field: String, panel: Int? = nil) throws -> Double {
            let subject = panel.map { "panel \($0)" } ?? "an entry"
            guard container.contains(key),
                  let value = try? container.decode(Double.self, forKey: key),
                  value.isFinite else {
                throw NanoleafTopologyProblem.malformed("\(subject) has no readable \(field)")
            }
            return value
        }
    }
}

// MARK: - Topology changes

/// How a freshly read layout differs from the last trusted one, in panel IDs.
/// Selections and saved designs are reconciled from this; nothing is ever
/// remapped by position in the list.
struct NanoleafTopologyChange: Equatable {
    let added: [Int]
    let removed: [Int]
    /// Same ID, but a different position, rotation or shape: the panel was
    /// moved or the wall was rebuilt around it.
    let moved: [Int]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && moved.isEmpty }

    static func between(_ old: NanoleafLayout?, _ new: NanoleafLayout) -> NanoleafTopologyChange {
        guard let old else { return NanoleafTopologyChange(added: [], removed: [], moved: []) }
        let before = Dictionary(uniqueKeysWithValues: old.paintablePanels.map { ($0.panelID, $0) })
        let after = Dictionary(uniqueKeysWithValues: new.paintablePanels.map { ($0.panelID, $0) })
        let added = after.keys.filter { before[$0] == nil }.sorted()
        let removed = before.keys.filter { after[$0] == nil }.sorted()
        let moved = after.compactMap { id, panel -> Int? in
            guard let previous = before[id] else { return nil }
            let shifted = abs(previous.x - panel.x) > 0.5 || abs(previous.y - panel.y) > 0.5
            let delta = NanoleafOrientation.normalized(previous.orientation - panel.orientation)
            let turned = delta > 0.5 && delta < 359.5
            return shifted || turned || previous.shapeCode != panel.shapeCode ? id : nil
        }.sorted()
        return NanoleafTopologyChange(added: added, removed: removed, moved: moved)
    }

    var summary: String? {
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) panel\(added.count == 1 ? "" : "s") added") }
        if !removed.isEmpty { parts.append("\(removed.count) panel\(removed.count == 1 ? "" : "s") no longer reported") }
        if !moved.isEmpty { parts.append("\(moved.count) panel\(moved.count == 1 ? "" : "s") moved") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
