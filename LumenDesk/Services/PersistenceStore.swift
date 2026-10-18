import Foundation

/// The complete structured configuration that survives app launches.
/// Lightweight view preferences remain in `UserDefaults` at their call sites.
struct PersistedApplicationState: Codable, Equatable {
    static let currentSchemaVersion = 3

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
    /// The per-panel design LumenDesk last applied to each Shapes wall,
    /// keyed by device ID.
    var nanoleafDesigns: [String: NanoleafPanelDesign] = [:]
    var nanoleafSavedDesigns: [NanoleafSavedDesign] = []
    var nanoleafPanelGroups: [String: [NanoleafPanelGroup]] = [:]
    /// The last layout each controller reported that could be trusted, so
    /// the editor can draw a wall before its controller answers.
    var nanoleafArrangements: [String: NanoleafArrangement] = [:]

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
        case nanoleafDesigns
        case nanoleafSavedDesigns
        case nanoleafPanelGroups
        case nanoleafArrangements
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
        // Entry by entry: one damaged design or layout is dropped on its own
        // instead of taking every other wall's with it.
        nanoleafDesigns = (try? container.decode(LossyDictionary<NanoleafPanelDesign>.self, forKey: .nanoleafDesigns))?.values ?? [:]
        nanoleafSavedDesigns = (try? container.decode(LossyArray<NanoleafSavedDesign>.self, forKey: .nanoleafSavedDesigns))?.values ?? []
        nanoleafPanelGroups = (try? container.decode(LossyDictionary<[NanoleafPanelGroup]>.self, forKey: .nanoleafPanelGroups))?.values ?? [:]
        nanoleafArrangements = (try? container.decode(LossyDictionary<NanoleafArrangement>.self, forKey: .nanoleafArrangements))?.values ?? [:]
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

/// SQLite-backed structured application storage with one-time migration from
/// the JSON file and individual `UserDefaults` values used by earlier
/// LumenDesk releases. JSON remains the portable Room/Look backup format.
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
        /// Which lights the user put in white (kelvin) mode rather than colour
        /// mode. A per-device setting made in the UI, so it belongs in an
        /// exported configuration; it used to persist locally and silently
        /// drop out of every export.
        var whiteModeDeviceIDs: [String]?
        var goveeSegmentStates: [String: GoveeSegmentState]?
        var goveeSegmentPresets: [GoveeSegmentPreset]?
        var musicModeConfiguration: MusicModeConfiguration?
        var fixtureTopologies: [String: FixtureTopology]?
        /// Shapes designs, saved designs, panel groups and known layouts.
        /// Pairing credentials are never part of an export: they live only
        /// in this device's Keychain.
        var nanoleafDesigns: [String: NanoleafPanelDesign]?
        var nanoleafSavedDesigns: [NanoleafSavedDesign]?
        var nanoleafPanelGroups: [String: [NanoleafPanelGroup]]?
        var nanoleafArrangements: [String: NanoleafArrangement]?

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
            whiteModeDeviceIDs: [String]?,
            goveeSegmentStates: [String: GoveeSegmentState]?,
            goveeSegmentPresets: [GoveeSegmentPreset]?,
            musicModeConfiguration: MusicModeConfiguration?,
            fixtureTopologies: [String: FixtureTopology]?,
            nanoleafDesigns: [String: NanoleafPanelDesign]? = nil,
            nanoleafSavedDesigns: [NanoleafSavedDesign]? = nil,
            nanoleafPanelGroups: [String: [NanoleafPanelGroup]]? = nil,
            nanoleafArrangements: [String: NanoleafArrangement]? = nil
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
            self.whiteModeDeviceIDs = whiteModeDeviceIDs
            self.goveeSegmentStates = goveeSegmentStates
            self.goveeSegmentPresets = goveeSegmentPresets
            self.musicModeConfiguration = musicModeConfiguration
            self.fixtureTopologies = fixtureTopologies
            self.nanoleafDesigns = nanoleafDesigns
            self.nanoleafSavedDesigns = nanoleafSavedDesigns
            self.nanoleafPanelGroups = nanoleafPanelGroups
            self.nanoleafArrangements = nanoleafArrangements
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
            case whiteModeDeviceIDs
            case goveeSegmentStates
            case goveeSegmentPresets
            case musicModeConfiguration
            case fixtureTopologies
            case nanoleafDesigns
            case nanoleafSavedDesigns
            case nanoleafPanelGroups
            case nanoleafArrangements
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
            whiteModeDeviceIDs = try container.decodeIfPresent([String].self, forKey: .whiteModeDeviceIDs)
            goveeSegmentStates = try container.decodeIfPresent([String: GoveeSegmentState].self, forKey: .goveeSegmentStates)
            goveeSegmentPresets = try container.decodeIfPresent([GoveeSegmentPreset].self, forKey: .goveeSegmentPresets)
            musicModeConfiguration = try container.decodeIfPresent(MusicModeConfiguration.self, forKey: .musicModeConfiguration)
            fixtureTopologies = try container.decodeIfPresent([String: FixtureTopology].self, forKey: .fixtureTopologies)
            // Lossy per entry, and absent in exports from older versions.
            nanoleafDesigns = (try? container.decodeIfPresent(LossyDictionary<NanoleafPanelDesign>.self, forKey: .nanoleafDesigns))?.values
            nanoleafSavedDesigns = (try? container.decodeIfPresent(LossyArray<NanoleafSavedDesign>.self, forKey: .nanoleafSavedDesigns))?.values
            nanoleafPanelGroups = (try? container.decodeIfPresent(LossyDictionary<[NanoleafPanelGroup]>.self, forKey: .nanoleafPanelGroups))?.values
            nanoleafArrangements = (try? container.decodeIfPresent(LossyDictionary<NanoleafArrangement>.self, forKey: .nanoleafArrangements))?.values
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
    private let legacyStateFileURL: URL?
    private let legacyDefaults: UserDefaults?
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let database: SQLiteStateDatabase

    init(
        fileURL: URL,
        legacyStateFileURL: URL? = nil,
        legacyDefaults: UserDefaults? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.legacyStateFileURL = legacyStateFileURL
        self.legacyDefaults = legacyDefaults
        self.fileManager = fileManager
        database = SQLiteStateDatabase(fileURL: fileURL, fileManager: fileManager)
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
        let directory = root.appendingPathComponent("LumenDesk", isDirectory: true)
        let fileURL = directory.appendingPathComponent("RoomCanvas.sqlite3", isDirectory: false)
        let legacyFileURL = directory.appendingPathComponent("ApplicationState.json", isDirectory: false)
        return PersistenceStore(
            fileURL: fileURL,
            legacyStateFileURL: legacyFileURL,
            legacyDefaults: legacyDefaults,
            fileManager: fileManager
        )
    }

    func load() -> PersistedApplicationState {
        if SQLiteStateDatabase.isSQLiteFile(at: fileURL) {
            do {
                var state = try database.load()
                guard state.schemaVersion <= PersistedApplicationState.currentSchemaVersion else {
                    return PersistedApplicationState()
                }
                let previousVersion = state.schemaVersion
                state = migratedAndNormalized(state)
                if previousVersion != state.schemaVersion { try? save(state) }
                return state
            } catch {
                if isUnsupportedDatabaseVersion(error) { return PersistedApplicationState() }
            }

            do {
                var state = try recoverDatabaseBackup()
                guard state.schemaVersion <= PersistedApplicationState.currentSchemaVersion else {
                    return PersistedApplicationState()
                }
                let previousVersion = state.schemaVersion
                state = migratedAndNormalized(state)
                if previousVersion != state.schemaVersion { try? save(state) }
                return state
            } catch {
                if isUnsupportedDatabaseVersion(error) { return PersistedApplicationState() }
            }

            // A valid SQLite signature does not guarantee a readable database.
            // Preserve the failed primary, then keep walking the migration path
            // so a still-valid ApplicationState.json can restore Rooms & Looks.
            quarantineUnreadableDatabase()
        }

        // Tests, development builds, and 1.x installs can place the previous
        // JSON payload at the new store URL. Decode it before SQLite attempts
        // to open the bytes as a database, preserve a sidecar copy, then
        // migrate it atomically.
        if fileManager.fileExists(atPath: fileURL.path) {
            if let state = loadJSONState(at: fileURL) {
                let migrated = migratedAndNormalized(state)
                try? migrateJSON(migrated, from: fileURL, occupiesDatabaseURL: true)
                return migrated
            }
            // A torn or otherwise damaged SQLite header cannot be identified
            // as SQLite. Try the last transaction backup before treating the
            // file as an unknown legacy payload.
            do {
                let recovered = try recoverDatabaseBackup()
                return migratedAndNormalized(recovered)
            } catch {
                if isUnsupportedDatabaseVersion(error) { return PersistedApplicationState() }
            }
        }

        if let legacyStateFileURL,
           fileManager.fileExists(atPath: legacyStateFileURL.path),
           let state = loadJSONState(at: legacyStateFileURL) {
            let migrated = migratedAndNormalized(state)
            try? migrateJSON(migrated, from: legacyStateFileURL, occupiesDatabaseURL: false)
            return migrated
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
        if fileManager.fileExists(atPath: fileURL.path),
           !SQLiteStateDatabase.isSQLiteFile(at: fileURL) {
            try preserveLegacyJSON(at: fileURL)
            try fileManager.removeItem(at: fileURL)
        }
        try database.save(normalized)
    }

    func exportConfiguration(from state: PersistedApplicationState) throws -> Data {
        let state = migratedAndNormalized(state)
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
            whiteModeDeviceIDs: Array(state.whiteModeDeviceIDs),
            goveeSegmentStates: state.goveeSegmentStates,
            goveeSegmentPresets: state.goveeSegmentPresets,
            musicModeConfiguration: state.musicModeConfiguration,
            fixtureTopologies: state.fixtureTopologies,
            nanoleafDesigns: state.nanoleafDesigns,
            nanoleafSavedDesigns: state.nanoleafSavedDesigns,
            nanoleafPanelGroups: state.nanoleafPanelGroups,
            nanoleafArrangements: state.nanoleafArrangements
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
            // Older exports carry no white-mode list; keep what this install knows.
            if let whiteModeDeviceIDs = archive.whiteModeDeviceIDs {
                next.whiteModeDeviceIDs = Set(whiteModeDeviceIDs)
            }
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
            // Older exports have no Shapes data; keep what this install knows.
            if let designs = archive.nanoleafDesigns { next.nanoleafDesigns = designs }
            if let saved = archive.nanoleafSavedDesigns { next.nanoleafSavedDesigns = saved }
            if let groups = archive.nanoleafPanelGroups { next.nanoleafPanelGroups = groups }
            if let arrangements = archive.nanoleafArrangements { next.nanoleafArrangements = arrangements }
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
        migrated.rooms = migrated.rooms.map { room in
            var value = room
            // Direction A makes no unattended guarantee. Old schedules stay
            // recoverable in the preserved JSON sidecar, but never enter the
            // foreground Room Canvas store or execute after migration.
            value.schedules = []
            return value
        }
        migrated.solarPreferences = .init()
        migrated.automationOverrides = [:]
        migrated.activityEvents = []
        migrated.parliamentMembers = []
        migrated.parliamentSessions = []
        migrated.sceneCertifications = []
        migrated.scenes = migrated.scenes.map { $0.normalized() }
        migrated.sceneDrafts = migrated.sceneDrafts.mapValues { $0.normalized() }
        return migrated
    }

    private func loadJSONState(at url: URL) -> PersistedApplicationState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(PersistedApplicationState.self, from: data),
              state.schemaVersion <= PersistedApplicationState.currentSchemaVersion else {
            return nil
        }
        return state
    }

    private func migrateJSON(
        _ state: PersistedApplicationState,
        from sourceURL: URL,
        occupiesDatabaseURL: Bool
    ) throws {
        try preserveLegacyJSON(at: sourceURL)
        if occupiesDatabaseURL { try fileManager.removeItem(at: sourceURL) }
        try database.save(state)
    }

    private func preserveLegacyJSON(at sourceURL: URL) throws {
        let archiveURL = fileURL.appendingPathExtension("legacy.json")
        guard !fileManager.fileExists(atPath: archiveURL.path) else { return }
        try fileManager.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceURL, to: archiveURL)
    }

    private func recoverDatabaseBackup() throws -> PersistedApplicationState {
        let recovered = try database.loadBackup()
        // Keep the corrupt primary for diagnosis and make the last complete
        // transaction the active store again. No Room or Look is discarded.
        let corruptURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.moveItem(at: fileURL, to: corruptURL)
        }
        try? fileManager.copyItem(at: database.backupURL, to: fileURL)
        return recovered
    }

    private func isUnsupportedDatabaseVersion(_ error: Error) -> Bool {
        guard let databaseError = error as? SQLiteStateDatabase.DatabaseError else { return false }
        if case .unsupportedVersion = databaseError { return true }
        return false
    }

    private func quarantineUnreadableDatabase() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let quarantineURL = fileURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
        try? fileManager.moveItem(at: fileURL, to: quarantineURL)

        // SQLite can leave these beside a failed primary. Moving them prevents
        // stale journal pages from being attached to the newly migrated store.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: fileURL.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            let quarantinedSidecar = URL(fileURLWithPath: quarantineURL.path + suffix)
            try? fileManager.moveItem(at: sidecar, to: quarantinedSidecar)
        }
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
