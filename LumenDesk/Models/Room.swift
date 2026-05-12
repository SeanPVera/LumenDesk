import Foundation

/// A user-defined grouping of lights. Rooms are vendor-agnostic — a single room
/// can contain LIFX and Govee bulbs side by side, independent of how each vendor
/// app groups them.
struct Room: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Ordered list of `LightDevice.id` values assigned to this room.
    var lightIDs: [String]

    init(id: UUID = UUID(), name: String, lightIDs: [String] = []) {
        self.id = id
        self.name = name
        self.lightIDs = lightIDs
    }
}
