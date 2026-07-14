import Foundation
import XCTest
@testable import LumenDesk

final class PersistenceStoreTests: XCTestCase {
    func testStructuredStateRoundTripPreservesCurrentData() throws {
        let store = temporaryPersistenceStore()
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

        XCTAssertEqual(store.load(), state)
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

    func testLegacyDefaultsMigrationPreservesRoomsScenesFavoritesSchedulesAndSegments() throws {
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

        XCTAssertEqual(migrated.rooms, [room])
        XCTAssertEqual(migrated.rooms.first?.schedules, [schedule])
        XCTAssertEqual(migrated.scenes, [scene])
        XCTAssertEqual(migrated.favoriteIDs, ["govee:strip"])
        XCTAssertEqual(migrated.favoriteRoomIDs, [roomID])
        XCTAssertEqual(migrated.favoriteSceneIDs, [sceneID])
        XCTAssertEqual(migrated.goveeSegmentStates, ["govee:strip": segments])
        XCTAssertEqual(migrated.goveeSegmentPresets.map(\.name), ["Migrated"])
        XCTAssertEqual(migrated.solarPreferences.sunriseHour, 8)
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

        let exported = try store.exportConfiguration(from: source)
        let imported = try store.importingConfiguration(
            from: exported,
            into: PersistedApplicationState()
        )

        XCTAssertEqual(imported.rooms, source.rooms)
        XCTAssertEqual(imported.scenes, source.scenes)
        XCTAssertEqual(imported.favoriteRoomIDs, source.favoriteRoomIDs)
        XCTAssertEqual(imported.favoriteSceneIDs, source.favoriteSceneIDs)
        XCTAssertEqual(imported.customNames, source.customNames)
        XCTAssertEqual(imported.customBrightnessPresets, source.customBrightnessPresets)

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
