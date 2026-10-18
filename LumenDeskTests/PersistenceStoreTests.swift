import Foundation
import SQLite3
import XCTest
@testable import LumenDesk

final class PersistenceStoreTests: XCTestCase {
    func testStructuredStateRoundTripPreservesCurrentData() throws {
        let fileURL = temporaryPersistenceFileURL()
        let store = PersistenceStore(fileURL: fileURL)
        let roomID = UUID()
        let sceneID = UUID()
        let schedule = ScheduleEntry(hour: 7, minute: 45, action: .dim50, weekdays: [2, 4, 6])
        let room = Room(id: roomID, name: "Office", lightIDs: ["lifx:desk"], schedules: [schedule])
        let segments = GoveeSegmentState(
            colors: [.init(red: 1, green: 0.2, blue: 0.1, brightness: 0.7)],
            gradient: true,
            isActive: true
        )
        let scene = LightingScene(
            id: sceneID,
            name: "Focus",
            snapshots: [
                "govee:strip": DeviceSnapshot(
                    isOn: true,
                    brightness: 0.62,
                    hue: 0.8,
                    saturation: 0.7,
                    segments: segments
                )
            ]
        )
        var state = PersistedApplicationState()
        state.rooms = [room]
        state.favoriteIDs = ["lifx:desk"]
        state.scenes = [scene]
        state.customNames = ["lifx:desk": "Desk"]
        state.collapsedRooms = [roomID]
        state.solarPreferences = .init(
            sunriseHour: 7,
            sunriseMinute: 5,
            sunsetHour: 19,
            sunsetMinute: 40
        )
        state.whiteModeDeviceIDs = ["lifx:desk"]
        state.favoriteRoomIDs = [roomID]
        state.favoriteSceneIDs = [sceneID]
        state.customBrightnessPresets = [0.2, 0.55]
        state.favoriteOrder = [FavoriteReference(kind: .room, rawID: roomID.uuidString)]
        state.automationOverrides = [
            roomID: RoomAutomationOverride(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil,
                skipNextSchedule: true
            )
        ]
        state.sceneRevisions = [SceneRevision(scene: scene, label: "Before edit")]
        state.sceneDrafts = [sceneID: scene]
        state.goveeSegmentStates = ["govee:strip": segments]
        state.goveeSegmentPresets = [
            GoveeSegmentPreset(name: "Warm", stops: segments.colors)
        ]

        try store.save(state)

        let loaded = store.load()
        XCTAssertEqual(loaded.rooms.first?.name, "Office")
        XCTAssertEqual(loaded.rooms.first?.lightIDs, ["lifx:desk"])
        XCTAssertTrue(loaded.rooms.first?.schedules.isEmpty == true)
        XCTAssertEqual(loaded.scenes, [scene])
        XCTAssertEqual(loaded.customNames, state.customNames)
        XCTAssertEqual(loaded.goveeSegmentStates, state.goveeSegmentStates)
        XCTAssertEqual(loaded.solarPreferences, .init())
        XCTAssertTrue(loaded.automationOverrides.isEmpty)
        XCTAssertTrue(SQLiteStateDatabase.isSQLiteFile(at: fileURL))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fileURL.appendingPathExtension("backup").path
        ))
    }

    func testMissingAndPartiallyMissingDataFallsBackSafely() throws {
        let missingStore = temporaryPersistenceStore()
        XCTAssertEqual(missingStore.load(), PersistedApplicationState())

        let room = Room(name: "Recovered Room")
        let roomData = try JSONEncoder().encode([room])
        let roomJSON = try XCTUnwrap(String(data: roomData, encoding: .utf8))
        let fileURL = temporaryPersistenceFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"schemaVersion\":0,\"rooms\":\(roomJSON),\"scenes\":\"damaged\"}".utf8)
            .write(to: fileURL)

        let loaded = PersistenceStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.rooms, [room])
        XCTAssertTrue(loaded.scenes.isEmpty)
        XCTAssertEqual(loaded.schemaVersion, PersistedApplicationState.currentSchemaVersion)
        XCTAssertTrue(SQLiteStateDatabase.isSQLiteFile(at: fileURL))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fileURL.appendingPathExtension("legacy.json").path
        ))
    }

    func testMalformedStateFileDoesNotCrashAndReturnsSafeDefaults() throws {
        let fileURL = temporaryPersistenceFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fileURL)

        XCTAssertEqual(
            PersistenceStore(fileURL: fileURL).load(),
            PersistedApplicationState()
        )
    }

    func testCorruptPrimaryRecoversLastCompleteSQLiteTransaction() throws {
        let fileURL = temporaryPersistenceFileURL()
        let store = PersistenceStore(fileURL: fileURL)
        var state = PersistedApplicationState()
        state.rooms = [Room(name: "Recovered Room")]
        state.scenes = [LightingScene(name: "Recovered Look", snapshots: [:])]
        try store.save(state)

        try Data("damaged database header".utf8).write(to: fileURL)
        let recovered = store.load()

        XCTAssertEqual(recovered.rooms.map(\.name), ["Recovered Room"])
        XCTAssertEqual(recovered.scenes.map(\.name), ["Recovered Look"])
        XCTAssertTrue(SQLiteStateDatabase.isSQLiteFile(at: fileURL))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains { $0.lastPathComponent.hasPrefix("ApplicationState.json.corrupt-") })
    }

    func testUnreadableSQLiteFallsBackToPreservedLegacyState() throws {
        let root = temporaryPersistenceFileURL().deletingLastPathComponent()
        let databaseURL = root.appendingPathComponent("RoomCanvas.sqlite3", isDirectory: false)
        let legacyURL = root.appendingPathComponent("ApplicationState.json", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var corruptSQLite = Data("SQLite format 3\0".utf8)
        corruptSQLite.append(Data(repeating: 0xA5, count: 128))
        try corruptSQLite.write(to: databaseURL)
        try corruptSQLite.write(to: databaseURL.appendingPathExtension("backup"))

        var legacyState = PersistedApplicationState()
        legacyState.rooms = [Room(name: "Legacy Room")]
        legacyState.scenes = [LightingScene(name: "Legacy Look", snapshots: [:])]
        try JSONEncoder().encode(legacyState).write(to: legacyURL)

        let store = PersistenceStore(
            fileURL: databaseURL,
            legacyStateFileURL: legacyURL
        )
        let recovered = store.load()

        XCTAssertEqual(recovered.rooms.map(\.name), ["Legacy Room"])
        XCTAssertEqual(recovered.scenes.map(\.name), ["Legacy Look"])
        XCTAssertTrue(SQLiteStateDatabase.isSQLiteFile(at: databaseURL))
        XCTAssertEqual(PersistenceStore(fileURL: databaseURL).load(), recovered)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(siblings.contains {
            $0.lastPathComponent.hasPrefix("RoomCanvas.sqlite3.unreadable-")
        })
    }

    func testNewerSQLiteStoreVersionIsLeftUntouched() throws {
        let root = temporaryPersistenceFileURL().deletingLastPathComponent()
        let databaseURL = root.appendingPathComponent("RoomCanvas.sqlite3", isDirectory: false)
        let backupURL = databaseURL.appendingPathExtension("backup")
        let legacyURL = root.appendingPathComponent("ApplicationState.json", isDirectory: false)
        let store = PersistenceStore(fileURL: databaseURL, legacyStateFileURL: legacyURL)

        var currentState = PersistedApplicationState()
        currentState.rooms = [Room(name: "Newer Room")]
        try store.save(currentState)
        var staleLegacyState = PersistedApplicationState()
        staleLegacyState.rooms = [Room(name: "Stale Legacy Room")]
        try JSONEncoder().encode(staleLegacyState).write(to: legacyURL)

        let newerVersion = SQLiteStateDatabase.storeVersion + 1
        setSQLiteStoreVersion(newerVersion, at: databaseURL)
        setSQLiteStoreVersion(newerVersion, at: backupURL)
        let primaryBeforeLoad = try Data(contentsOf: databaseURL)
        let backupBeforeLoad = try Data(contentsOf: backupURL)

        XCTAssertEqual(store.load(), PersistedApplicationState())
        XCTAssertEqual(try Data(contentsOf: databaseURL), primaryBeforeLoad)
        XCTAssertEqual(try Data(contentsOf: backupURL), backupBeforeLoad)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".unreadable-") })
    }

    func testLegacyDefaultsMigrationPreservesRoomsLooksFavoritesAndSegments() throws {
        let defaults = isolatedPersistenceDefaults()
        let roomID = UUID()
        let sceneID = UUID()
        let schedule = ScheduleEntry(hour: 21, minute: 15, action: .turnOff)
        let room = Room(id: roomID, name: "Living Room", lightIDs: ["govee:strip"], schedules: [schedule])
        let segments = GoveeSegmentState(
            colors: [.init(red: 0.2, green: 0.4, blue: 1)],
            isActive: true
        )
        let scene = LightingScene(
            id: sceneID,
            name: "Evening",
            snapshots: [
                "govee:strip": DeviceSnapshot(
                    isOn: true,
                    brightness: 0.5,
                    hue: 0.7,
                    saturation: 0.8,
                    segments: segments
                )
            ]
        )
        try setLegacy([room], key: "LumenDesk.rooms.v1", defaults: defaults)
        try setLegacy([scene], key: "LumenDesk.scenes.v1", defaults: defaults)
        try setLegacy(["govee:strip"], key: "LumenDesk.favorites.v1", defaults: defaults)
        try setLegacy([roomID], key: "LumenDesk.favoriteRooms.v1", defaults: defaults)
        try setLegacy([sceneID], key: "LumenDesk.favoriteScenes.v1", defaults: defaults)
        try setLegacy(["govee:strip": segments], key: "LumenDesk.goveeSegments.v1", defaults: defaults)
        try setLegacy(
            [GoveeSegmentPreset(name: "Migrated", stops: segments.colors)],
            key: "LumenDesk.segmentPresets.v1",
            defaults: defaults
        )
        defaults.set(
            ["sunriseHour": 8, "sunriseMinute": 10, "sunsetHour": 18, "sunsetMinute": 20],
            forKey: "LumenDesk.solar.v1"
        )
        let fileURL = temporaryPersistenceFileURL()
        let store = PersistenceStore(fileURL: fileURL, legacyDefaults: defaults)

        let migrated = store.load()

        XCTAssertEqual(migrated.rooms.first?.id, room.id)
        XCTAssertEqual(migrated.rooms.first?.name, room.name)
        XCTAssertTrue(migrated.rooms.first?.schedules.isEmpty == true)
        XCTAssertEqual(migrated.scenes, [scene])
        XCTAssertEqual(migrated.favoriteIDs, ["govee:strip"])
        XCTAssertEqual(migrated.favoriteRoomIDs, [roomID])
        XCTAssertEqual(migrated.favoriteSceneIDs, [sceneID])
        XCTAssertEqual(migrated.goveeSegmentStates, ["govee:strip": segments])
        XCTAssertEqual(migrated.goveeSegmentPresets.map(\.name), ["Migrated"])
        XCTAssertEqual(migrated.solarPreferences, .init())
        XCTAssertEqual(migrated.schemaVersion, PersistedApplicationState.currentSchemaVersion)

        // A new store without access to legacy defaults reads the migrated file.
        XCTAssertEqual(PersistenceStore(fileURL: fileURL).load(), migrated)
    }

    func testExportImportRoundTripAndLegacyRoomImport() throws {
        let store = temporaryPersistenceStore()
        let room = Room(name: "Office", schedules: [
            ScheduleEntry(hour: 9, minute: 0, action: .turnOn)
        ])
        let scene = LightingScene(name: "Focus", snapshots: [:])
        var source = PersistedApplicationState()
        source.rooms = [room]
        source.scenes = [scene]
        source.favoriteRoomIDs = [room.id]
        source.favoriteSceneIDs = [scene.id]
        source.customNames = ["lifx:a": "Desk"]
        source.customBrightnessPresets = [0.35]
        source.whiteModeDeviceIDs = ["lifx:a", "govee:strip"]

        let exported = try store.exportConfiguration(from: source)
        let imported = try store.importingConfiguration(
            from: exported,
            into: PersistedApplicationState()
        )

        XCTAssertEqual(imported.rooms.first?.id, room.id)
        XCTAssertTrue(imported.rooms.first?.schedules.isEmpty == true)
        XCTAssertEqual(imported.scenes, source.scenes)
        XCTAssertEqual(imported.favoriteRoomIDs, source.favoriteRoomIDs)
        XCTAssertEqual(imported.favoriteSceneIDs, source.favoriteSceneIDs)
        XCTAssertEqual(imported.customNames, source.customNames)
        XCTAssertEqual(imported.customBrightnessPresets, source.customBrightnessPresets)
        // Which lights the user put in white mode is a per-device setting made
        // in the UI, so it has to travel with the configuration. It used to
        // persist locally and drop silently out of every export, leaving every
        // light in colour mode on the machine that imported it.
        XCTAssertEqual(imported.whiteModeDeviceIDs, source.whiteModeDeviceIDs)

        // A configuration exported before that field existed still imports, and
        // leaves this install's own white-mode choices alone.
        var legacyArchive = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        legacyArchive.removeValue(forKey: "whiteModeDeviceIDs")
        var keepsOwn = PersistedApplicationState()
        keepsOwn.whiteModeDeviceIDs = ["lifx:local"]
        let fromLegacy = try store.importingConfiguration(
            from: try JSONSerialization.data(withJSONObject: legacyArchive),
            into: keepsOwn
        )
        XCTAssertEqual(fromLegacy.whiteModeDeviceIDs, ["lifx:local"])
        XCTAssertEqual(fromLegacy.rooms.first?.id, room.id)
        XCTAssertTrue(fromLegacy.rooms.first?.schedules.isEmpty == true)

        var existing = source
        existing.scenes = [LightingScene(name: "Keep Me", snapshots: [:])]
        let legacyRooms = [Room(name: "Legacy Room")]
        let legacyImport = try store.importingConfiguration(
            from: JSONEncoder().encode(legacyRooms),
            into: existing
        )
        XCTAssertEqual(legacyImport.rooms, legacyRooms)
        XCTAssertEqual(legacyImport.scenes, existing.scenes)
    }

    func testFailedImportLeavesCurrentStateUnchanged() throws {
        let store = temporaryPersistenceStore()
        var current = PersistedApplicationState()
        current.rooms = [Room(name: "Current Room")]
        current.scenes = [LightingScene(name: "Current Scene", snapshots: [:])]

        XCTAssertThrowsError(
            try store.importingConfiguration(from: Data("invalid".utf8), into: current)
        )
        XCTAssertEqual(store.load(), PersistedApplicationState())
        XCTAssertEqual(current.rooms.map(\.name), ["Current Room"])
        XCTAssertEqual(current.scenes.map(\.name), ["Current Scene"])
    }

    func testFullAndLegacyImportsRetireUnattendedScheduleFields() throws {
        let store = temporaryPersistenceStore()
        let schedule: [String: Any] = [
            "id": UUID().uuidString, "isEnabled": true, "hour": Int.max,
            "minute": Int.min, "offsetMinutes": Int.max, "action": "turnOn",
            "weekdays": [0, 2, 8]
        ]
        let room: [String: Any] = [
            "id": UUID().uuidString, "name": "Imported", "lightIDs": [],
            "schedules": [schedule]
        ]
        var archive = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: store.exportConfiguration(from: PersistedApplicationState())) as? [String: Any])
        archive["rooms"] = [room]
        archive["sunriseHour"] = Int.max
        archive["sunriseMinute"] = Int.min
        archive["sunsetHour"] = Int.min
        archive["sunsetMinute"] = Int.max
        let full = try store.importingConfiguration(
            from: JSONSerialization.data(withJSONObject: archive), into: PersistedApplicationState())
        let legacy = try store.importingConfiguration(
            from: JSONSerialization.data(withJSONObject: [room]), into: PersistedApplicationState())
        for imported in [full, legacy] {
            XCTAssertTrue(imported.rooms.first?.schedules.isEmpty == true)
            try store.save(imported)
            XCTAssertEqual(store.load().rooms, imported.rooms)
        }
        XCTAssertEqual(full.solarPreferences, .init())
    }

    func testImportedSceneChannelsAreSafeForLANConversionsAndLegacyDefaults() throws {
        let store = temporaryPersistenceStore()
        var source = PersistedApplicationState()
        source.scenes = [LightingScene(name: "Imported", snapshots: [:])]
        var archive = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: store.exportConfiguration(from: source)) as? [String: Any])
        var scenes = try XCTUnwrap(archive["scenes"] as? [[String: Any]])
        scenes[0]["snapshots"] = [
            "lifx:malformed": ["isOn": true, "brightness": 2.0, "hue": -2.0,
                               "saturation": 3.0, "kelvin": -1],
            "nanoleaf:legacy": ["isOn": true, "brightness": 0.4, "hue": 0.2,
                                "saturation": 0.7]
        ]
        archive["scenes"] = scenes
        let imported = try store.importingConfiguration(
            from: JSONSerialization.data(withJSONObject: archive), into: PersistedApplicationState())
        let snapshots = try XCTUnwrap(imported.scenes.first?.snapshots)
        let malformed = try XCTUnwrap(snapshots["lifx:malformed"])
        XCTAssertEqual(malformed.brightness, 1)
        XCTAssertEqual(malformed.hue, 0)
        XCTAssertEqual(malformed.saturation, 1)
        XCTAssertEqual(malformed.kelvin, 1200)
        XCTAssertEqual(UInt16(malformed.brightness * 65535), 65535)
        XCTAssertEqual(UInt16(malformed.kelvin), 1200)
        XCTAssertEqual(snapshots["nanoleaf:legacy"]?.kelvin, 3500)
        try store.save(imported)
        XCTAssertEqual(store.load().scenes, imported.scenes)
    }

    func testProgrammaticNonFiniteSceneValuesNormalizeInSaveAndExport() throws {
        let store = temporaryPersistenceStore()
        var snapshot = DeviceSnapshot(isOn: true, brightness: 0.5, hue: 0.2, saturation: 0.7)
        snapshot.brightness = .infinity
        snapshot.hue = .nan
        snapshot.saturation = -.infinity
        snapshot.kelvin = Int.max
        var scene = LightingScene(name: "Malformed", snapshots: [:])
        scene.snapshots["lifx:fixture"] = snapshot
        var state = PersistedApplicationState()
        state.scenes = [scene]
        state.sceneDrafts[scene.id] = scene
        try store.save(state)
        let loaded = store.load()
        let saved = try XCTUnwrap(loaded.scenes.first?.snapshots["lifx:fixture"])
        XCTAssertEqual(saved.brightness, 0)
        XCTAssertEqual(saved.hue, 0)
        XCTAssertEqual(saved.saturation, 0)
        XCTAssertEqual(saved.kelvin, 9000)
        XCTAssertEqual(loaded.sceneDrafts[scene.id]?.snapshots["lifx:fixture"], saved)
        let exported = try store.exportConfiguration(from: state)
        let imported = try store.importingConfiguration(from: exported, into: PersistedApplicationState())
        XCTAssertEqual(imported.scenes, loaded.scenes)
        XCTAssertEqual(DeviceSnapshot(isOn: true, brightness: .nan, hue: .infinity,
                                      saturation: -.infinity, kelvin: Int.min).kelvin, 1200)
    }

    @MainActor
    func testDemoModeCannotWriteToLivePersistence() {
        let spy = PersistenceSpy()
        spy.loadedState.rooms = [Room(name: "Live Room")]
        let manager = LightManager(
            defaults: isolatedPersistenceDefaults(),
            persistenceStore: spy
        )

        manager.enterDemoMode()
        manager.createRoom(name: "Demo Room")
        manager.captureScene(name: "Demo Scene")
        manager.addBrightnessPreset(0.88)
        manager.setSunriseTime(hour: 1, minute: 15)

        XCTAssertTrue(manager.isDemoMode)
        XCTAssertEqual(spy.savedStates.count, 0)
        manager.exitDemoMode()
        XCTAssertEqual(manager.rooms.map(\.name), ["Live Room"])
        XCTAssertEqual(spy.savedStates.count, 0)
    }

    @MainActor
    func testImportSaveFailureDoesNotReplaceLiveManagerState() {
        let spy = PersistenceSpy()
        spy.loadedState.rooms = [Room(name: "Current Room")]
        spy.importedState.rooms = [Room(name: "Imported Room")]
        spy.saveError = PersistenceStore.ImportError.invalidConfiguration
        let manager = LightManager(
            defaults: isolatedPersistenceDefaults(),
            persistenceStore: spy
        )

        XCTAssertFalse(manager.importRoomsData(Data("candidate".utf8)))
        XCTAssertEqual(manager.rooms.map(\.name), ["Current Room"])
        XCTAssertEqual(spy.saveAttempts, 1)
    }

    private func setLegacy<Value: Encodable>(
        _ value: Value,
        key: String,
        defaults: UserDefaults
    ) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }

    private func setSQLiteStoreVersion(_ version: Int32, at url: URL) {
        var connection: OpaquePointer?
        let openResult = sqlite3_open(url.path, &connection)
        XCTAssertEqual(openResult, SQLITE_OK)
        guard let connection else { return }
        defer { sqlite3_close(connection) }
        XCTAssertEqual(
            sqlite3_exec(connection, "PRAGMA user_version = \(version)", nil, nil, nil),
            SQLITE_OK
        )
    }
}

private final class PersistenceSpy: ApplicationPersistence {
    var loadedState = PersistedApplicationState()
    var importedState = PersistedApplicationState()
    var savedStates: [PersistedApplicationState] = []
    var saveAttempts = 0
    var saveError: Error?

    func load() -> PersistedApplicationState { loadedState }

    func save(_ state: PersistedApplicationState) throws {
        saveAttempts += 1
        if let saveError { throw saveError }
        savedStates.append(state)
    }

    func exportConfiguration(from state: PersistedApplicationState) throws -> Data {
        Data()
    }

    func importingConfiguration(
        from data: Data,
        into currentState: PersistedApplicationState
    ) throws -> PersistedApplicationState {
        importedState
    }
}

func temporaryPersistenceStore(
    legacyDefaults: UserDefaults? = nil
) -> PersistenceStore {
    PersistenceStore(
        fileURL: temporaryPersistenceFileURL(),
        legacyDefaults: legacyDefaults
    )
}

func temporaryPersistenceFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("LumenDeskTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("ApplicationState.json", isDirectory: false)
}

func isolatedPersistenceDefaults() -> UserDefaults {
    UserDefaults(suiteName: "LumenDeskTests.Persistence.\(UUID().uuidString)")!
}
