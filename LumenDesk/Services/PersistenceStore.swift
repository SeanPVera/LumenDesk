import Foundation

/// The complete structured configuration that survives app launches.
/// Lightweight view preferences remain in `UserDefaults` at their call sites.
struct PersistedApplicationState: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var rooms: [Room] = []
    var favoriteIDs: Set<String> = []
    var scenes: [LightingScene] = []
    var customNames: [String: String] = [:]
    var collapsedRooms: Set<UUID> = []
    var solarPreferences = SolarPreferences()
    var whiteModeDeviceIDs: Set<String> = []
    var favoriteRoomIDs: Set<UUID> = []
    var favoriteSceneIDs: Set<UUID> = []
    var customBrightnessPresets: [Double] = []
    var activityEvents: [ActivityEvent] = []
    var favoriteOrder: [FavoriteReference] = []
    var parliamentMembers: [ParliamentMember] = []
    var parliamentSessions: [ParliamentSession] = []
    var sceneCertifications: [SceneCertification] = []
    var recentColors: [RecentColor] = []
    var automationOverrides: [UUID: RoomAutomationOverride] = [:]
    var sceneRevisions: [SceneRevision] = []
    var sceneDrafts: [UUID: LightingScene] = [:]
    var goveeSegmentStates: [String: GoveeSegmentState] = [:]
    var goveeSegmentPresets: [GoveeSegmentPreset] = []
    var musicModeConfiguration = MusicModeConfiguration.configuration(for: .soundcheck)
    var fixtureTopologies: [String: FixtureTopology] = [:]

    struct SolarPreferences: Codable, Equatable {
        var sunriseHour: Int = 6
        var sunriseMinute: Int = 30
        var sunsetHour: Int = 20
        var sunsetMinute: Int = 30
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case rooms
        case favoriteIDs
        case scenes
        case customNames
        case collapsedRooms
        case solarPreferences
        case whiteModeDeviceIDs
        case favoriteRoomIDs
        case favoriteSceneIDs
        case customBrightnessPresets
        case activityEvents
        case favoriteOrder
        case parliamentMembers
        case parliamentSessions
        case sceneCertifications
        case recentColors
        case automationOverrides
        case sceneRevisions
        case sceneDrafts
        case goveeSegmentStates
        case goveeSegmentPresets
        case musicModeConfiguration
        case fixtureTopologies
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        rooms = (try? container.decode([Room].self, forKey: .rooms)) ?? []
        favoriteIDs = (try? container.decode(Set<String>.self, forKey: .favoriteIDs)) ?? []
        scenes = (try? container.decode([LightingScene].self, forKey: .scenes)) ?? []
        customNames = (try? container.decode([String: String].self, forKey: .customNames)) ?? [:]
        collapsedRooms = (try? container.decode(Set<UUID>.self, forKey: .collapsedRooms)) ?? []
        solarPreferences = (try? container.decode(SolarPreferences.self, forKey: .solarPreferences)) ?? SolarPreferences()
        whiteModeDeviceIDs = (try? container.decode(Set<String>.self, forKey: .whiteModeDeviceIDs)) ?? []
        favoriteRoomIDs = (try? container.decode(Set<UUID>.self, forKey: .favoriteRoomIDs)) ?? []
        favoriteSceneIDs = (try? container.decode(Set<UUID>.self, forKey: .favoriteSceneIDs)) ?? []
        customBrightnessPresets = (try? container.decode([Double].self, forKey: .customBrightnessPresets)) ?? []
        activityEvents = (try? container.decode([ActivityEvent].self, forKey: .activityEvents)) ?? []
        favoriteOrder = (try? container.decode([FavoriteReference].self, forKey: .favoriteOrder)) ?? []
        parliamentMembers = (try? container.decode([ParliamentMember].self, forKey: .parliamentMembers)) ?? []
        parliamentSessions = (try? container.decode([ParliamentSession].self, forKey: .parliamentSessions)) ?? []
        sceneCertifications = (try? container.decode([SceneCertification].self, forKey: .sceneCertifications)) ?? []
        recentColors = (try? container.decode([RecentColor].self, forKey: .recentColors)) ?? []
        automationOverrides = (try? container.decode([UUID: RoomAutomationOverride].self, forKey: .automationOverrides)) ?? [:]
        sceneRevisions = (try? container.decode([SceneRevision].self, forKey: .sceneRevisions)) ?? []
        sceneDrafts = (try? container.decode([UUID: LightingScene].self, forKey: .sceneDrafts)) ?? [:]
        goveeSegmentStates = (try? container.decode([String: GoveeSegmentState].self, forKey: .goveeSegmentStates)) ?? [:]
        goveeSegmentPresets = (try? container.decode([GoveeSegmentPreset].self, forKey: .goveeSegmentPresets)) ?? []
        musicModeConfiguration = ((try? container.decode(MusicModeConfiguration.self, forKey: .musicModeConfiguration))
            ?? .configuration(for: .soundcheck)).normalized()
        fixtureTopologies = (try? container.decode([String: FixtureTopology].self, forKey: .fixtureTopologies)) ?? [:]
    }
}

/// Useful ownership boundary for injecting a file store or a test spy into
/// `LightManager` without giving the store any dependency on SwiftUI.
protocol ApplicationPersistence: AnyObject {
    func load() -> PersistedApplicationState
    func save(_ state: PersistedApplicationState) throws
    func exportConfiguration(from state: PersistedApplicationState) throws -> Data
    func importingConfiguration(
        from data: Data,
        into currentState: PersistedApplicationState
    ) throws -> PersistedApplicationState
}

/// File-backed structured application storage with one-time migration from
/// the individual `UserDefaults` values used by earlier LumenDesk releases.
final class PersistenceStore: ApplicationPersistence {
    struct ConfigurationArchive: Codable, Equatable {
        var schemaVersion: Int
        var rooms: [Room]
        var favoriteIDs: [String]
        var favoriteRoomIDs: [UUID]
        var favoriteSceneIDs: [UUID]
        var scenes: [LightingScene]
        var customNames: [String: String]
        var collapsedRooms: [UUID]
        var sunriseHour: Int
        var sunriseMinute: Int
        var sunsetHour: Int
        var sunsetMinute: Int
        var brightnessPresets: [Double]
        // Optional so configurations exported by earlier versions still import.
        var goveeSegmentStates: [String: GoveeSegmentState]?
        var goveeSegmentPresets: [GoveeSegmentPreset]?
        var musicModeConfiguration: MusicModeConfiguration?
        var fixtureTopologies: [String: FixtureTopology]?

        init(
            schemaVersion: Int = PersistedApplicationState.currentSchemaVersion,
            rooms: [Room],
            favoriteIDs: [String],
            favoriteRoomIDs: [UUID],
            favoriteSceneIDs: [UUID],
            scenes: [LightingScene],
            customNames: [String: String],
            collapsedRooms: [UUID],
            sunriseHour: Int,
            sunriseMinute: Int,
            sunsetHour: Int,
            sunsetMinute: Int,
            brightnessPresets: [Double],
            goveeSegmentStates: [String: GoveeSegmentState]?,
            goveeSegmentPresets: [GoveeSegmentPreset]?,
            musicModeConfiguration: MusicModeConfiguration?,
            fixtureTopologies: [String: FixtureTopology]?
        ) {
            self.schemaVersion = schemaVersion
            self.rooms = rooms
            self.favoriteIDs = favoriteIDs
            self.favoriteRoomIDs = favoriteRoomIDs
            self.favoriteSceneIDs = favoriteSceneIDs
            self.scenes = scenes
            self.customNames = customNames
            self.collapsedRooms = collapsedRooms
            self.sunriseHour = sunriseHour
            self.sunriseMinute = sunriseMinute
            self.sunsetHour = sunsetHour
            self.sunsetMinute = sunsetMinute
            self.brightnessPresets = brightnessPresets
            self.goveeSegmentStates = goveeSegmentStates
            self.goveeSegmentPresets = goveeSegmentPresets
            self.musicModeConfiguration = musicModeConfiguration
            self.fixtureTopologies = fixtureTopologies
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case rooms
            case favoriteIDs
            case favoriteRoomIDs
            case favoriteSceneIDs
            case scenes
            case customNames
            case collapsedRooms
            case sunriseHour
            case sunriseMinute
            case sunsetHour
            case sunsetMinute
            case brightnessPresets
            case goveeSegmentStates
            case goveeSegmentPresets
            case musicModeConfiguration
            case fixtureTopologies
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
            rooms = try container.decode([Room].self, forKey: .rooms)
            favoriteIDs = try container.decode([String].self, forKey: .favoriteIDs)
            favoriteRoomIDs = try container.decode([UUID].self, forKey: .favoriteRoomIDs)
            favoriteSceneIDs = try container.decode([UUID].self, forKey: .favoriteSceneIDs)
            scenes = try container.decode([LightingScene].self, forKey: .scenes)
            customNames = try container.decode([String: String].self, forKey: .customNames)
            collapsedRooms = try container.decode([UUID].self, forKey: .collapsedRooms)
            sunriseHour = try container.decode(Int.self, forKey: .sunriseHour)
            sunriseMinute = try container.decode(Int.self, forKey: .sunriseMinute)
            sunsetHour = try container.decode(Int.self, forKey: .sunsetHour)
            sunsetMinute = try container.decode(Int.self, forKey: .sunsetMinute)
            brightnessPresets = try container.decode([Double].self, forKey: .brightnessPresets)
            goveeSegmentStates = try container.decodeIfPresent([String: GoveeSegmentState].self, forKey: .goveeSegmentStates)
            goveeSegmentPresets = try container.decodeIfPresent([GoveeSegmentPreset].self, forKey: .goveeSegmentPresets)
            musicModeConfiguration = try container.decodeIfPresent(MusicModeConfiguration.self, forKey: .musicModeConfiguration)
            fixtureTopologies = try container.decodeIfPresent([String: FixtureTopology].self, forKey: .fixtureTopologies)
        }
    }

    enum ImportError: Error, Equatable {
        case invalidConfiguration
        case unsupportedSchemaVersion(Int)
    }

    private enum LegacyKey {
        static let rooms = "LumenDesk.rooms.v1"
        static let favorites = "LumenDesk.favorites.v1"
        static let scenes = "LumenDesk.scenes.v1"
        static let customNames = "LumenDesk.customNames.v1"
        static let collapsedRooms = "LumenDesk.collapsedRooms.v1"
        static let solar = "LumenDesk.solar.v1"
        static let whiteMode = "LumenDesk.whiteMode.v1"
        static let favoriteRooms = "LumenDesk.favoriteRooms.v1"
        static let favoriteScenes = "LumenDesk.favoriteScenes.v1"
        static let brightnessPresets = "LumenDesk.brightnessPresets.v1"
        static let activity = "LumenDesk.activity.v1"
        static let favoriteOrder = "LumenDesk.favoriteOrder.v1"
        static let parliament = "LumenDesk.parliament.v1"
        static let parliamentSessions = "LumenDesk.parliamentSessions.v1"
        static let certifications = "LumenDesk.certifications.v1"
        static let recentColors = "LumenDesk.recentColors.v1"
        static let automationOverrides = "LumenDesk.automationOverrides.v1"
        static let sceneRevisions = "LumenDesk.sceneRevisions.v1"
        static let sceneDrafts = "LumenDesk.sceneDrafts.v1"
        static let goveeSegments = "LumenDesk.goveeSegments.v1"
        static let segmentPresets = "LumenDesk.segmentPresets.v1"

        static let all = [
            rooms, favorites, scenes, customNames, collapsedRooms, solar,
            whiteMode, favoriteRooms, favoriteScenes, brightnessPresets,
            activity, favoriteOrder, parliament, parliamentSessions,
            certifications, recentColors, automationOverrides,
            sceneRevisions, sceneDrafts, goveeSegments, segmentPresets
        ]
    }

    private let fileURL: URL
    private let legacyDefaults: UserDefaults?
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL,
        legacyDefaults: UserDefaults? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    static func live(
        legacyDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> PersistenceStore {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let fileURL = root
            .appendingPathComponent("LumenDesk", isDirectory: true)
            .appendingPathComponent("ApplicationState.json", isDirectory: false)
        return PersistenceStore(
            fileURL: fileURL,
            legacyDefaults: legacyDefaults,
            fileManager: fileManager
        )
    }

    func load() -> PersistedApplicationState {
        if fileManager.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  var state = try? decoder.decode(PersistedApplicationState.self, from: data),
                  state.schemaVersion <= PersistedApplicationState.currentSchemaVersion else {
                return PersistedApplicationState()
            }
            let previousVersion = state.schemaVersion
            state = migratedAndNormalized(state)
            if previousVersion != state.schemaVersion { try? save(state) }
            return state
        }

        guard let legacyState = loadLegacyState() else {
            return PersistedApplicationState()
        }
        let migrated = migratedAndNormalized(legacyState)
        try? save(migrated)
        return migrated
    }

    func save(_ state: PersistedApplicationState) throws {
        let normalized = migratedAndNormalized(state)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(normalized).write(to: fileURL, options: .atomic)
    }

    func exportConfiguration(from state: PersistedApplicationState) throws -> Data {
        let solar = state.solarPreferences
        let archive = ConfigurationArchive(
            rooms: state.rooms,
            favoriteIDs: Array(state.favoriteIDs),
            favoriteRoomIDs: Array(state.favoriteRoomIDs),
            favoriteSceneIDs: Array(state.favoriteSceneIDs),
            scenes: state.scenes,
            customNames: state.customNames,
            collapsedRooms: Array(state.collapsedRooms),
            sunriseHour: solar.sunriseHour,
            sunriseMinute: solar.sunriseMinute,
            sunsetHour: solar.sunsetHour,
            sunsetMinute: solar.sunsetMinute,
            brightnessPresets: state.customBrightnessPresets,
            goveeSegmentStates: state.goveeSegmentStates,
            goveeSegmentPresets: state.goveeSegmentPresets,
            musicModeConfiguration: state.musicModeConfiguration,
            fixtureTopologies: state.fixtureTopologies
        )
        return try encoder.encode(archive)
    }

    func importingConfiguration(
        from data: Data,
        into currentState: PersistedApplicationState
    ) throws -> PersistedApplicationState {
        if let archive = try? decoder.decode(ConfigurationArchive.self, from: data) {
            guard archive.schemaVersion <= PersistedApplicationState.currentSchemaVersion else {
                throw ImportError.unsupportedSchemaVersion(archive.schemaVersion)
            }
            var next = currentState
            next.rooms = archive.rooms
            next.favoriteIDs = Set(archive.favoriteIDs)
            next.favoriteRoomIDs = Set(archive.favoriteRoomIDs)
            next.favoriteSceneIDs = Set(archive.favoriteSceneIDs)
            next.scenes = archive.scenes
            next.customNames = archive.customNames
            next.collapsedRooms = Set(archive.collapsedRooms)
            next.solarPreferences = .init(
                sunriseHour: archive.sunriseHour,
                sunriseMinute: archive.sunriseMinute,
                sunsetHour: archive.sunsetHour,
                sunsetMinute: archive.sunsetMinute
            )
            next.customBrightnessPresets = archive.brightnessPresets
            // Older exports have no segment data; keep what this install knows.
            if let segmentStates = archive.goveeSegmentStates {
                next.goveeSegmentStates = segmentStates
            }
            if let segmentPresets = archive.goveeSegmentPresets {
                next.goveeSegmentPresets = segmentPresets
            }
            if let musicConfiguration = archive.musicModeConfiguration {
                next.musicModeConfiguration = musicConfiguration.normalized()
            }
            if let topologies = archive.fixtureTopologies {
                next.fixtureTopologies = topologies
            }
            next.favoriteOrder = reconciledFavoriteOrder(in: next)
            return migratedAndNormalized(next)
        }

        if let rooms = try? decoder.decode([Room].self, from: data) {
            var next = currentState
            next.rooms = rooms
            return migratedAndNormalized(next)
        }

        throw ImportError.invalidConfiguration
    }

    static func sanitizedBrightnessPresets(_ values: [Double]) -> [Double] {
        var seen: Set<Int> = []
        return values
            .filter(\.isFinite)
            .map { max(0.01, min(1.0, $0)) }
            .sorted()
            .filter { value in
                let key = Int((value * 100).rounded())
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
    }

    private func migratedAndNormalized(
        _ state: PersistedApplicationState
    ) -> PersistedApplicationState {
        var migrated = state
        // Schema 0 represents migrated per-key defaults and early unversioned
        // state files. Its Codable model already supplies safe field defaults.
        migrated.schemaVersion = PersistedApplicationState.currentSchemaVersion
        migrated.customBrightnessPresets = Self.sanitizedBrightnessPresets(
            migrated.customBrightnessPresets
        )
        migrated.musicModeConfiguration = migrated.musicModeConfiguration.normalized()
        return migrated
    }

    private func reconciledFavoriteOrder(
        in state: PersistedApplicationState
    ) -> [FavoriteReference] {
        let active = Set(
            state.favoriteIDs.map { FavoriteReference(kind: .light, rawID: $0) }
                + state.favoriteRoomIDs.map { FavoriteReference(kind: .room, rawID: $0.uuidString) }
                + state.favoriteSceneIDs.map { FavoriteReference(kind: .scene, rawID: $0.uuidString) }
        )
        var order = state.favoriteOrder.filter(active.contains)
        order.append(contentsOf: active.filter { !order.contains($0) }.sorted { $0.id < $1.id })
        return order
    }

    private func loadLegacyState() -> PersistedApplicationState? {
        guard let defaults = legacyDefaults,
              LegacyKey.all.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return nil
        }

        var state = PersistedApplicationState()
        state.schemaVersion = 0
        state.rooms = legacyValue([Room].self, key: LegacyKey.rooms, defaults: defaults) ?? []
        state.favoriteIDs = Set(legacyValue([String].self, key: LegacyKey.favorites, defaults: defaults) ?? [])
        state.scenes = legacyValue([LightingScene].self, key: LegacyKey.scenes, defaults: defaults) ?? []
        state.customNames = legacyValue([String: String].self, key: LegacyKey.customNames, defaults: defaults) ?? [:]
        state.collapsedRooms = Set(legacyValue([UUID].self, key: LegacyKey.collapsedRooms, defaults: defaults) ?? [])
        state.whiteModeDeviceIDs = Set(legacyValue([String].self, key: LegacyKey.whiteMode, defaults: defaults) ?? [])
        state.favoriteRoomIDs = Set(legacyValue([UUID].self, key: LegacyKey.favoriteRooms, defaults: defaults) ?? [])
        state.favoriteSceneIDs = Set(legacyValue([UUID].self, key: LegacyKey.favoriteScenes, defaults: defaults) ?? [])
        state.customBrightnessPresets = legacyValue([Double].self, key: LegacyKey.brightnessPresets, defaults: defaults) ?? []
        state.activityEvents = legacyValue([ActivityEvent].self, key: LegacyKey.activity, defaults: defaults) ?? []
        state.favoriteOrder = legacyValue([FavoriteReference].self, key: LegacyKey.favoriteOrder, defaults: defaults) ?? []
        state.parliamentMembers = legacyValue([ParliamentMember].self, key: LegacyKey.parliament, defaults: defaults) ?? []
        state.parliamentSessions = legacyValue([ParliamentSession].self, key: LegacyKey.parliamentSessions, defaults: defaults) ?? []
        state.sceneCertifications = legacyValue([SceneCertification].self, key: LegacyKey.certifications, defaults: defaults) ?? []
        state.recentColors = legacyValue([RecentColor].self, key: LegacyKey.recentColors, defaults: defaults) ?? []
        state.automationOverrides = legacyValue([UUID: RoomAutomationOverride].self, key: LegacyKey.automationOverrides, defaults: defaults) ?? [:]
        state.sceneRevisions = legacyValue([SceneRevision].self, key: LegacyKey.sceneRevisions, defaults: defaults) ?? []
        state.sceneDrafts = legacyValue([UUID: LightingScene].self, key: LegacyKey.sceneDrafts, defaults: defaults) ?? [:]
        state.goveeSegmentStates = legacyValue([String: GoveeSegmentState].self, key: LegacyKey.goveeSegments, defaults: defaults) ?? [:]
        state.goveeSegmentPresets = legacyValue([GoveeSegmentPreset].self, key: LegacyKey.segmentPresets, defaults: defaults) ?? []

        if let solar = defaults.dictionary(forKey: LegacyKey.solar) {
            state.solarPreferences = .init(
                sunriseHour: solar["sunriseHour"] as? Int ?? 6,
                sunriseMinute: solar["sunriseMinute"] as? Int ?? 30,
                sunsetHour: solar["sunsetHour"] as? Int ?? 20,
                sunsetMinute: solar["sunsetMinute"] as? Int ?? 30
            )
        }
        return state
    }

    private func legacyValue<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        defaults: UserDefaults
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
