import Foundation

/// A saved snapshot of every discovered light's state — power, brightness, and
/// hue/saturation — that can be recalled with one tap to recreate a lighting
/// mood. Only lights present in `snapshots` are affected when applied; lights
/// added after the scene was captured are left alone.
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

struct DeviceSnapshot: Codable, Equatable {
    var isOn: Bool
    var brightness: Double
    var hue: Double
    var saturation: Double
}
