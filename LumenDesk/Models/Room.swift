import Foundation

/// A target for bulk lighting actions — themes, effects, colors — covering
/// either every discovered light or just the lights assigned to one room.
enum LightScope: Hashable, Sendable {
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

    /// Where this room's block sits on the plan board.
    ///
    /// Nil until the board has been arranged, which happens lazily the first
    /// time a plan is drawn. Storing it here rather than in a side table means
    /// `ConfigurationArchive`, which already carries `[Room]` whole, exports
    /// and imports a plan for free.
    var planFrame: RoomPlanFrame?

    /// Where each fixture stands inside the block, keyed by light ID and
    /// measured as a fraction of the block in each axis. Fixtures without an
    /// entry fall back to `PlanLayout.defaultAnchors`, so a room is drawable
    /// before anyone has dragged a single dot.
    var fixtureAnchors: [String: PlanAnchor]

    init(id: UUID = UUID(), name: String, lightIDs: [String] = [], schedules: [ScheduleEntry] = [],
         planFrame: RoomPlanFrame? = nil, fixtureAnchors: [String: PlanAnchor] = [:]) {
        self.id = id
        self.name = name
        self.lightIDs = lightIDs
        self.schedules = schedules
        self.planFrame = planFrame
        self.fixtureAnchors = fixtureAnchors
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lightIDs, schedules, planFrame, fixtureAnchors
    }

    // Custom decoder so existing saved data (without the schedules key) loads cleanly.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lightIDs = try container.decode([String].self, forKey: .lightIDs)
        schedules = (try? container.decode([ScheduleEntry].self, forKey: .schedules)) ?? []
        // Archives written before the plan existed simply have no layout; the
        // board is laid out lazily on first draw rather than by a migration.
        planFrame = try? container.decode(RoomPlanFrame.self, forKey: .planFrame)
        fixtureAnchors = (try? container.decode([String: PlanAnchor].self, forKey: .fixtureAnchors)) ?? [:]
    }
}
