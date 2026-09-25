import Foundation

// MARK: - Request bodies

/// JSON bodies for the Shapes OpenAPI writes LumenDesk uses. Every one is a
/// documented endpoint; nothing here reaches a vendor service.
enum NanoleafCommand {
    /// `PUT /panelLayout`. The documented contract; the controller answers
    /// 204 with no body, so success is only known from reading the value back.
    static func orientation(_ degrees: Int) -> [String: Any] {
        ["globalOrientation": ["value": degrees]]
    }

    /// `PUT /effects`: show an effect already stored on the controller.
    static func select(_ name: String) -> [String: Any] {
        ["select": name]
    }

    /// Wraps an effect command the way `PUT /effects` expects it.
    static func write(_ body: [String: Any]) -> [String: Any] {
        ["write": body]
    }

    /// A static per-panel display that is not stored as a scene. The wall
    /// keeps showing it after LumenDesk quits; the controller reports it as
    /// the reserved effect `*Static*`.
    static func displayStatic(_ frames: [NanoleafPanelFrame]) -> [String: Any] {
        write(staticEffect(frames, command: "display"))
    }

    /// Stores a static per-panel design on the controller under `name`.
    /// `add` overwrites an effect of the same name, so callers check the
    /// effect list first and only overwrite on explicit confirmation.
    static func addStatic(name: String, frames: [NanoleafPanelFrame]) -> [String: Any] {
        var body = staticEffect(frames, command: "add")
        body["animName"] = name
        return write(body)
    }

    private static func staticEffect(_ frames: [NanoleafPanelFrame], command: String) -> [String: Any] {
        [
            "command": command,
            "version": "2.0",
            "animType": "static",
            "animData": NanoleafAnimData.staticString(frames),
            "loop": false,
            "palette": [] as [Any],
            "colorType": "HSB"
        ]
    }

    /// Turns on external control, protocol v2. For Shapes the controller
    /// answers with no body and listens on UDP 60222 at its own address.
    static let externalControl: [String: Any] = write([
        "command": "display",
        "animType": "extControl",
        "extControlVersion": "v2"
    ])

    static let requestAll: [String: Any] = write(["command": "requestAll"])
    static let requestPlugins: [String: Any] = write(["command": "requestPlugins", "version": "2.0"])

    static func request(_ name: String) -> [String: Any] {
        write(["command": "request", "animName": name])
    }

    /// A gentle, temporary "which panel is this" cue.
    ///
    /// `displayTemp` is Nanoleaf's notification mechanism: the controller
    /// shows the effect for `seconds` and then returns to whatever it was
    /// doing by itself, including an animated scene LumenDesk cannot read
    /// back. So identification never has to guess at a restore. The chosen
    /// panel breathes between white and a dim level about once a second —
    /// well under any flash threshold — while the rest of the wall holds a
    /// dim neutral so the shape stays legible.
    static func identifyPanel(_ panelID: Int, in layout: NanoleafLayout, seconds: Int = 4) -> [String: Any] {
        let dim = "20 20 20 0"
        var parts = [String(layout.paintablePanels.count)]
        for panel in layout.paintablePanels {
            if panel.panelID == panelID {
                parts.append("\(panel.panelID) 2 255 255 255 0 5 40 40 40 0 5")
            } else {
                parts.append("\(panel.panelID) 1 \(dim) 3")
            }
        }
        return write([
            "command": "displayTemp",
            "duration": max(1, min(30, seconds)),
            "version": "2.0",
            "animType": "custom",
            "animData": parts.joined(separator: " "),
            "loop": true,
            "palette": [] as [Any],
            "colorType": "HSB"
        ])
    }
}

// MARK: - Effect library

/// A plugin option value as the controller writes it.
enum NanoleafOptionValue: Equatable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var jsonObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }

    var displayText: String {
        switch self {
        case .bool(let value): return value ? "On" : "Off"
        case .int(let value): return String(value)
        case .double(let value): return String(format: "%.1f", value)
        case .string(let value): return value
        }
    }

    var numericValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}

extension NanoleafOptionValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first: JSONDecoder refuses to read a number as a Bool, which
        // is exactly the distinction needed and holds on every platform.
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported option value")
    }
}

struct NanoleafPaletteColor: Equatable, Hashable, Decodable {
    /// 0–359
    var hue: Int
    /// 0–100
    var saturation: Int
    /// 0–100
    var brightness: Int
    var probability: Double?

    init(hue: Int, saturation: Int, brightness: Int, probability: Double? = nil) {
        self.hue = min(359, max(0, hue))
        self.saturation = min(100, max(0, saturation))
        self.brightness = min(100, max(0, brightness))
        self.probability = probability
    }

    private enum Keys: String, CodingKey { case hue, saturation, brightness, probability }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        func whole(_ key: Keys) throws -> Int {
            let value = try container.decode(Double.self, forKey: key)
            guard value.isFinite else { throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not finite") }
            return Int(value.rounded())
        }
        self.init(hue: try whole(.hue), saturation: try whole(.saturation), brightness: try whole(.brightness),
                  probability: try? container.decodeIfPresent(Double.self, forKey: .probability))
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["hue": hue, "saturation": saturation, "brightness": brightness]
        if let probability { object["probability"] = probability }
        return object
    }
}

struct NanoleafEffectOption: Equatable, Hashable, Decodable {
    let name: String
    var value: NanoleafOptionValue
}

/// One effect stored on the controller, from `requestAll` or `request`.
///
/// `source` is the controller's definition, verbatim. Editing replaces the
/// palette and option values inside a copy of it and leaves every other
/// field alone, so saving an edit can never drop something LumenDesk does
/// not model.
struct NanoleafEffectDefinition: Equatable, Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case staticDesign
        case dynamic
        case rhythm

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .staticDesign: return "Static"
            case .dynamic: return "Dynamic"
            case .rhythm: return "Rhythm"
            }
        }
    }

    let name: String
    let animType: String
    let pluginType: String?
    let pluginUUID: String?
    var palette: [NanoleafPaletteColor]
    var options: [NanoleafEffectOption]
    let animData: String?
    let source: [String: Any]

    var id: String { name }

    var category: Category {
        if pluginType == "rhythm" { return .rhythm }
        if animType == "static" { return .staticDesign }
        if animType == "custom", let animData, let parsed = try? NanoleafAnimData.parse(animData),
           !parsed.isEmpty, parsed.values.allSatisfy({ $0.count == 1 }) {
            return .staticDesign
        }
        return .dynamic
    }

    /// Per-panel colours for a static effect, when its data can be read.
    var staticColors: [Int: NanoleafRGB]? {
        guard category == .staticDesign, let animData else { return nil }
        return try? NanoleafAnimData.settledColors(animData)
    }

    /// Plugin options and palette can be edited and written back. Static
    /// and custom effects carry their colours in `animData` instead.
    var hasEditableParameters: Bool { animType == "plugin" && (!palette.isEmpty || !options.isEmpty) }

    static func == (lhs: NanoleafEffectDefinition, rhs: NanoleafEffectDefinition) -> Bool {
        lhs.name == rhs.name && lhs.animType == rhs.animType && lhs.pluginType == rhs.pluginType
            && lhs.pluginUUID == rhs.pluginUUID && lhs.palette == rhs.palette && lhs.options == rhs.options
            && lhs.animData == rhs.animData
    }

    /// The definition with this effect's current palette and options, as a
    /// `write` body for `display` (preview, not stored) or `add` (store).
    func writeBody(command: String, name newName: String? = nil) -> [String: Any] {
        var body = source
        body["command"] = command
        if let newName { body["animName"] = newName } else if command == "display" { body.removeValue(forKey: "animName") }
        if source["palette"] != nil || source["Palette"] != nil || !palette.isEmpty {
            body.removeValue(forKey: "Palette")
            body["palette"] = palette.map(\.jsonObject)
        }
        if !options.isEmpty || source["pluginOptions"] != nil {
            body["pluginOptions"] = options.map { ["name": $0.name, "value": $0.value.jsonObject] }
        }
        return NanoleafCommand.write(body)
    }

    /// Reads the `animations` array of a `requestAll` response (or a single
    /// `request` response). Entries without a name are skipped, since the
    /// controller cannot select them; anything else unreadable fails.
    static func parseLibrary(_ data: Data) throws -> [NanoleafEffectDefinition] {
        let object = try JSONSerialization.jsonObject(with: data)
        let entries: [[String: Any]]
        if let dictionary = object as? [String: Any], let list = dictionary["animations"] as? [[String: Any]] {
            entries = list
        } else if let dictionary = object as? [String: Any], dictionary["animName"] != nil {
            entries = [dictionary]
        } else {
            throw NanoleafEffectLibraryError.unreadable
        }
        return try entries.compactMap { entry in
            guard let name = entry["animName"] as? String, !name.isEmpty else { return nil }
            return try definition(name: name, entry: entry)
        }
    }

    private static func definition(name: String, entry: [String: Any]) throws -> NanoleafEffectDefinition {
        let decoder = JSONDecoder()
        let paletteSource = entry["palette"] ?? entry["Palette"]
        var palette: [NanoleafPaletteColor] = []
        if let paletteSource, JSONSerialization.isValidJSONObject(["p": paletteSource]),
           let data = try? JSONSerialization.data(withJSONObject: paletteSource) {
            palette = (try? decoder.decode([NanoleafPaletteColor].self, from: data)) ?? []
        }
        var options: [NanoleafEffectOption] = []
        if let optionSource = entry["pluginOptions"], JSONSerialization.isValidJSONObject(["o": optionSource]),
           let data = try? JSONSerialization.data(withJSONObject: optionSource) {
            options = (try? decoder.decode([NanoleafEffectOption].self, from: data)) ?? []
        }
        return NanoleafEffectDefinition(
            name: name,
            animType: entry["animType"] as? String ?? "unknown",
            pluginType: entry["pluginType"] as? String,
            pluginUUID: entry["pluginUuid"] as? String,
            palette: palette,
            options: options,
            animData: entry["animData"] as? String,
            source: entry
        )
    }
}

enum NanoleafEffectLibraryError: Error, Equatable {
    case unreadable
}

/// A motion (plugin) installed on the controller, from `requestPlugins`:
/// what its options are and the range the controller accepts for each.
struct NanoleafPluginDescription: Equatable, Identifiable, Decodable {
    struct OptionSpec: Equatable, Decodable {
        let name: String
        let type: String
        let defaultValue: NanoleafOptionValue?
        let minValue: Double?
        let maxValue: Double?
        let strings: [String]?

        var choices: [String] { strings ?? [] }
    }

    let uuid: String
    let name: String
    let description: String?
    let type: String
    let pluginConfig: [OptionSpec]?

    var id: String { uuid }
    var options: [OptionSpec] { pluginConfig ?? [] }

    static func parseList(_ data: Data) throws -> [NanoleafPluginDescription] {
        struct Envelope: Decodable { let plugins: [NanoleafPluginDescription] }
        return try JSONDecoder().decode(Envelope.self, from: data).plugins
    }
}

extension NanoleafOptionValue {
    /// A person-facing name for the documented option keys.
    static func label(for name: String) -> String {
        switch name {
        case "transTime": return "Transition"
        case "delayTime": return "Hold"
        case "loop": return "Loop"
        case "linDirection": return "Direction"
        case "radDirection": return "Radial direction"
        case "rotDirection": return "Rotation"
        case "nColorsPerFrame": return "Colours shown"
        case "mainColorProb": return "Main colour share"
        default:
            // camelCase to words, so an undocumented option still reads.
            var words = ""
            for character in name {
                if character.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(character)
            }
            return words.prefix(1).uppercased() + words.dropFirst().lowercased()
        }
    }

    /// Time options are counted in tenths of a second.
    static func isTenthsOfSecond(_ name: String) -> Bool {
        name == "transTime" || name == "delayTime"
    }
}
