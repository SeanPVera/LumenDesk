import Foundation

struct LightingScene: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var snapshots: [String: DeviceSnapshot]
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         snapshots: [String: DeviceSnapshot],
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.snapshots = snapshots.mapValues { $0.normalized() }
        self.createdAt = createdAt
    }

    func normalized() -> LightingScene {
        var value = self
        value.snapshots = snapshots.mapValues { $0.normalized() }
        return value
    }
}

struct DeviceSnapshot: Equatable {
    var isOn: Bool
    var brightness: Double
    var hue: Double
    var saturation: Double
    var kelvin: Int
    /// Govee segment layout that was active when the scene was captured.
    /// Nil for solid-color devices and for scenes saved by older versions.
    var segments: GoveeSegmentState?
    /// LIFX matrix layout (including Luna's 26 zones) that was active when
    /// captured. Nil for solid-color devices and older scenes.
    var matrix: LIFXMatrixState?
    var nanoleafAppearance: NanoleafAppearance?
    /// The per-panel design a Nanoleaf Shapes wall was showing, keyed by
    /// panel ID. Nil when the wall showed anything else, and for scenes
    /// saved by older versions.
    var nanoleafDesign: NanoleafPanelDesign?

    init(isOn: Bool, brightness: Double, hue: Double, saturation: Double,
         kelvin: Int = 3500, segments: GoveeSegmentState? = nil,
         matrix: LIFXMatrixState? = nil, nanoleafAppearance: NanoleafAppearance? = nil,
         nanoleafDesign: NanoleafPanelDesign? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.kelvin = kelvin
        self.segments = segments
        self.matrix = matrix
        self.nanoleafAppearance = nanoleafAppearance
        self.nanoleafDesign = nanoleafDesign
        self = normalized()
    }

    /// Keep scene data safe before any numeric conversion to a LAN channel.
    /// The lower white point also preserves Nanoleaf's supported 1200 K state.
    func normalized() -> DeviceSnapshot {
        var value = self
        value.brightness = brightness.isFinite ? max(0, min(1, brightness)) : 0
        value.hue = hue.isFinite ? max(0, min(1, hue)) : 0
        value.saturation = saturation.isFinite ? max(0, min(1, saturation)) : 0
        value.kelvin = max(1200, min(9000, kelvin))
        return value
    }
}

extension DeviceSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case isOn, brightness, hue, saturation, kelvin, segments, matrix, nanoleafAppearance, nanoleafDesign
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decode(Bool.self, forKey: .isOn)
        brightness = try c.decode(Double.self, forKey: .brightness)
        hue = try c.decode(Double.self, forKey: .hue)
        saturation = try c.decode(Double.self, forKey: .saturation)
        kelvin = (try? c.decode(Int.self, forKey: .kelvin)) ?? 3500
        segments = try? c.decodeIfPresent(GoveeSegmentState.self, forKey: .segments)
        matrix = try? c.decodeIfPresent(LIFXMatrixState.self, forKey: .matrix)
        // Tolerant like the fields above: one unreadable value must not
        // fail the scene, and with it every scene in the archive.
        nanoleafAppearance = try? c.decodeIfPresent(NanoleafAppearance.self, forKey: .nanoleafAppearance)
        nanoleafDesign = try? c.decodeIfPresent(NanoleafPanelDesign.self, forKey: .nanoleafDesign)
        self = normalized()
    }
}
