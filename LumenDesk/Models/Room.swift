import Foundation

/// A target for bulk lighting actions — themes, effects, colors — covering
/// either every discovered light or just the lights assigned to one room.
enum LightScope: Hashable {
    case all
    case room(UUID)
}

/// A user-defined grouping of lights. Rooms are vendor-agnostic — a single room
/// can contain LIFX and Govee bulbs side by side, independent of how each vendor
/// app groups them.
struct Room: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Ordered list of `LightDevice.id` values assigned to this room.
    var lightIDs: [String]
    /// Daily automation entries for this room. Up to 4 per room.
    var schedules: [ScheduleEntry]

    init(id: UUID = UUID(), name: String, lightIDs: [String] = [], schedules: [ScheduleEntry] = []) {
        self.id = id
        self.name = name
        self.lightIDs = lightIDs
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lightIDs, schedules
    }

    // Custom decoder so existing saved data (without the schedules key) loads cleanly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lightIDs = try container.decode([String].self, forKey: .lightIDs)
        schedules = (try? container.decode([ScheduleEntry].self, forKey: .schedules)) ?? []
    }
}
