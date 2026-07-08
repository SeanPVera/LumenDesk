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
        self.snapshots = snapshots
        self.createdAt = createdAt
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

    init(isOn: Bool, brightness: Double, hue: Double, saturation: Double, kelvin: Int = 3500, segments: GoveeSegmentState? = nil) {
        self.isOn = isOn
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.kelvin = kelvin
        self.segments = segments
    }
}

extension DeviceSnapshot: Codable {
    enum CodingKeys: String, CodingKey {
        case isOn, brightness, hue, saturation, kelvin, segments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decode(Bool.self, forKey: .isOn)
        brightness = try c.decode(Double.self, forKey: .brightness)
        hue = try c.decode(Double.self, forKey: .hue)
        saturation = try c.decode(Double.self, forKey: .saturation)
        kelvin = (try? c.decode(Int.self, forKey: .kelvin)) ?? 3500
        segments = try? c.decodeIfPresent(GoveeSegmentState.self, forKey: .segments)
    }
}
