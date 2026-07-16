import XCTest
@testable import LumenDesk

final class DemoWorkspaceControllerTests: XCTestCase {
    @MainActor
    func testEnteringDemoModePreservesAndRestoresCompleteLiveWorkspace() async throws {
        let defaults = isolatedDefaults()
        let manager = LightManager(
            defaults: defaults,
            persistenceStore: temporaryPersistenceStore(legacyDefaults: defaults)
        )
        manager.lifxDiscovered(macHex: "AABBCCDDEEFF", address: "192.168.1.25")
        manager.goveeDiscovered(deviceID: "11:22:33:44", address: "192.168.1.26", sku: "H619A")
        await waitUntil { manager.devices.count == 2 }
        let liveLuna = LIFXMatrixState.demoLuna(brightness: 0.68)
        manager.lifxDidIdentify(macHex: "AABBCCDDEEFF", vendorID: 1, productID: 219)
        manager.lifxDidUpdateMatrix(
            macHex: "AABBCCDDEEFF",
            productID: 219,
            width: liveLuna.width,
            height: liveLuna.height,
            colors: liveLuna.colors.map(\.hsbk)
        )
        await waitUntil { !manager.lifxMatrixStates.isEmpty }

        let liveDevice = try XCTUnwrap(manager.devices.first { $0.brand == .lifx })
        let liveSegmentedDevice = try XCTUnwrap(manager.devices.first { $0.brand == .govee })
        manager.setCustomName(liveDevice.id, name: "Live Desk")
        manager.applySegments(
            liveSegmentedDevice,
            state: GoveeSegmentState(colors: [.init(red: 1, green: 0, blue: 0)], isActive: true),
            announce: false
        )
        manager.createRoom(name: "Live Office")
        let liveRoom = try XCTUnwrap(manager.rooms.first)
        manager.assign(lightIDs: [liveDevice.id, liveSegmentedDevice.id], toRoom: liveRoom.id)
        manager.captureScene(name: "Live Focus")
        let liveScene = try XCTUnwrap(manager.scenes.first)
        manager.toggleFavorite(liveDevice.id)
        manager.toggleFavoriteRoom(liveRoom.id)
        manager.toggleFavoriteScene(liveScene.id)
        manager.addBrightnessPreset(0.42)
        manager.setSunriseTime(hour: 7, minute: 15)
        manager.setSunsetTime(hour: 19, minute: 45)
        manager.setAutomationOverride(for: liveRoom.id, duration: .untilResumed)
        manager.reconcileFavoriteOrder()

        let liveRooms = manager.rooms
        let liveScenes = manager.scenes
        let liveFavoriteIDs = manager.favoriteIDs
        let liveFavoriteRoomIDs = manager.favoriteRoomIDs
        let liveFavoriteSceneIDs = manager.favoriteSceneIDs
        let liveFavoriteOrder = manager.favoriteOrder
        let liveActivity = manager.activityEvents
        let livePresets = manager.customBrightnessPresets
        let liveSegmentStates = manager.goveeSegmentStates
        let liveMatrixStates = manager.lifxMatrixStates
        let liveAutomationOverrides = manager.automationOverrides

        manager.enterDemoMode()
        XCTAssertTrue(manager.isDemoMode)
        XCTAssertEqual(manager.devices.count, 6)
        XCTAssertTrue(manager.devices.allSatisfy { $0.id.hasPrefix("demo:") })
        XCTAssertEqual(manager.rooms.map(\.name), ["Demo Office", "Demo Lounge"])
        XCTAssertTrue(manager.automationOverrides.isEmpty)

        manager.renameRoom(manager.rooms[0].id, to: "Changed Demo Room")
        manager.setCustomName(manager.devices[0].id, name: "Changed Demo Light")
        manager.captureScene(name: "Demo-only Scene")
        manager.setSunriseTime(hour: 1, minute: 2)
        manager.addBrightnessPreset(0.91)
        manager.setAutomationOverride(for: manager.rooms[0].id, duration: .nextSchedule)

        manager.exitDemoMode()

        XCTAssertFalse(manager.isDemoMode)
        XCTAssertEqual(manager.devices.count, 2)
        XCTAssertTrue(manager.devices.contains { $0 === liveDevice })
        XCTAssertEqual(manager.devices.first(where: { $0 === liveDevice })?.label, "Live Desk")
        XCTAssertEqual(manager.rooms, liveRooms)
        XCTAssertEqual(manager.scenes, liveScenes)
        XCTAssertEqual(manager.favoriteIDs, liveFavoriteIDs)
        XCTAssertEqual(manager.favoriteRoomIDs, liveFavoriteRoomIDs)
        XCTAssertEqual(manager.favoriteSceneIDs, liveFavoriteSceneIDs)
        XCTAssertEqual(manager.favoriteOrder, liveFavoriteOrder)
        XCTAssertEqual(manager.activityEvents, liveActivity)
        XCTAssertEqual(manager.customBrightnessPresets, livePresets)
        XCTAssertEqual(manager.goveeSegmentStates, liveSegmentStates)
        XCTAssertEqual(manager.lifxMatrixStates, liveMatrixStates)
        XCTAssertEqual(manager.automationOverrides, liveAutomationOverrides)
        XCTAssertEqual(manager.sunriseHour, 7)
        XCTAssertEqual(manager.sunriseMinute, 15)
        XCTAssertEqual(manager.sunsetHour, 19)
        XCTAssertEqual(manager.sunsetMinute, 45)
    }

    @MainActor
    func testDemoChangesCannotMutatePersistedLiveConfiguration() throws {
        let defaults = isolatedDefaults()
        let store = temporaryPersistenceStore(legacyDefaults: defaults)
        let manager = LightManager(defaults: defaults, persistenceStore: store)
        manager.createRoom(name: "Persisted Live Room")
        manager.captureScene(name: "Persisted Live Scene")
        manager.addBrightnessPreset(0.44)
        manager.setSunriseTime(hour: 8, minute: 5)

        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        manager.createRoom(name: "Demo Leak")
        manager.captureScene(name: "Demo Leak Scene")
        manager.toggleFavorite(manager.devices[0].id)
        manager.toggleFavoriteRoom(manager.rooms[0].id)
        manager.toggleFavoriteScene(manager.scenes[0].id)
        manager.addBrightnessPreset(0.99)
        manager.setSunriseTime(hour: 2, minute: 30)
        manager.setCustomName(manager.devices[0].id, name: "Demo-only Name")
        let segmentedDemoDevice = try XCTUnwrap(manager.devices.first { manager.segmentProfile(for: $0) != nil })
        manager.applySegments(
            segmentedDemoDevice,
            state: GoveeSegmentState(colors: [.init(red: 0, green: 1, blue: 0)], isActive: true),
            announce: false
        )

        let reloaded = LightManager(defaults: defaults, persistenceStore: store)
        XCTAssertEqual(reloaded.rooms.map(\.name), ["Persisted Live Room"])
        XCTAssertEqual(reloaded.scenes.map(\.name), ["Persisted Live Scene"])
        XCTAssertEqual(reloaded.customBrightnessPresets, [0.44])
        XCTAssertEqual(reloaded.sunriseHour, 8)
        XCTAssertEqual(reloaded.sunriseMinute, 5)
        XCTAssertTrue(reloaded.favoriteIDs.isEmpty)
        XCTAssertTrue(reloaded.favoriteRoomIDs.isEmpty)
        XCTAssertTrue(reloaded.favoriteSceneIDs.isEmpty)
        XCTAssertTrue(reloaded.goveeSegmentStates.isEmpty)
        let exportedData = try XCTUnwrap(reloaded.exportConfigurationData())
        let exported = try JSONDecoder().decode(LightManager.ExportedConfiguration.self, from: exportedData)
        XCTAssertTrue(exported.customNames.isEmpty)
    }

    @MainActor
    func testLiveNetworkCallbacksAreIgnoredDuringDemoMode() async {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let demoIDs = manager.devices.map(\.id)

        manager.lifxDiscovered(macHex: "LIVE-CALLBACK", address: "192.168.1.50")
        manager.goveeDiscovered(deviceID: "AA:BB:CC:DD", address: "192.168.1.51", sku: "H619A")
        await settleMainActorTasks()

        XCTAssertEqual(manager.devices.map(\.id), demoIDs)
        XCTAssertFalse(manager.devices.contains { $0.id.contains("LIVE-CALLBACK") || $0.id.contains("AA:BB:CC:DD") })
    }

    @MainActor
    func testRepeatedEnterExitCyclesRemainStable() {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        manager.createRoom(name: "Stable Live Room")
        manager.captureScene(name: "Stable Live Scene")
        let liveRooms = manager.rooms
        let liveScenes = manager.scenes

        for cycle in 0..<4 {
            manager.enterDemoMode()
            XCTAssertTrue(manager.isDemoMode)
            manager.renameRoom(manager.rooms[0].id, to: "Demo Cycle \(cycle)")
            manager.toggleFavorite(manager.devices[cycle].id)
            manager.exitDemoMode()

            XCTAssertFalse(manager.isDemoMode)
            XCTAssertEqual(manager.rooms, liveRooms)
            XCTAssertEqual(manager.scenes, liveScenes)
            XCTAssertTrue(manager.favoriteIDs.isEmpty)
        }
    }

    @MainActor
    func testResetDemoModeRestoresMusicDefaultsAndClearsRunningSessions() {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }

        let scope = LightScope.room(manager.rooms[0].id)
        manager.renameRoom(manager.rooms[0].id, to: "Changed Demo Room")
        manager.setMusicModeConfiguration(.configuration(for: .concert))
        manager.setFixtureTopology(
            FixtureTopology(layout: .custom, fixtureOrder: Array(manager.musicFixtureDescriptors(in: scope).map(\.id).reversed())),
            for: scope
        )
        var running = manager.musicModeConfiguration
        running.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: running, scope: scope)

        XCTAssertFalse(manager.activeEffects.isEmpty)
        XCTAssertFalse(manager.fixtureTopologies.isEmpty)

        manager.resetDemoMode()

        XCTAssertTrue(manager.isDemoMode)
        XCTAssertEqual(manager.rooms.map(\.name), ["Demo Office", "Demo Lounge"])
        XCTAssertEqual(manager.musicModeConfiguration.preset, .balanced)
        XCTAssertTrue(manager.musicModeConfiguration.usesSyntheticDemoPattern)
        XCTAssertTrue(manager.fixtureTopologies.isEmpty)
        XCTAssertTrue(manager.activeEffects.isEmpty)
        XCTAssertTrue(manager.musicModeController.activeScopeIDs.isEmpty)
    }

    @MainActor
    func testResumableAndCancelledTransientStateFollowsExistingPolicy() throws {
        let defaults = isolatedDefaults()
        defaults.set(ConfirmationPolicy.cautious.rawValue, forKey: AppPreferenceKey.confirmationPolicy)
        let manager = LightManager(
            defaults: defaults,
            persistenceStore: temporaryPersistenceStore()
        )
        manager.createRoom(name: "Pending Live Room")
        let roomID = try XCTUnwrap(manager.rooms.first?.id)
        manager.startNapMode()
        let liveNapPhase = manager.napPhase
        manager.deleteRoom(roomID)
        XCTAssertNotNil(manager.confirmationCoordinator.pendingRequest)

        manager.enterDemoMode()
        XCTAssertEqual(manager.napPhase, .inactive)
        XCTAssertNil(manager.confirmationCoordinator.pendingRequest)

        manager.exitDemoMode()
        XCTAssertEqual(manager.napPhase, liveNapPhase)
        XCTAssertNil(manager.confirmationCoordinator.pendingRequest)
        XCTAssertEqual(manager.rooms.first?.id, roomID)
        manager.cancelNapMode()
    }

    @MainActor
    func testSimulatedDiscoveryUsesOnlyDemoDevices() async {
        let controller = DemoWorkspaceController(discoveryDelayNanoseconds: 0)
        let manager = LightManager(
            defaults: isolatedDefaults(),
            demoWorkspaceController: controller,
            persistenceStore: temporaryPersistenceStore()
        )
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }

        manager.scan()
        await waitUntil { !manager.isScanning }

        XCTAssertEqual(manager.scanResponseCount, 5)
        XCTAssertEqual(manager.scanPhase, "Demo scan complete: 5 simulated responses")
        XCTAssertEqual(manager.devices.count, 6)
        XCTAssertTrue(manager.devices.allSatisfy { $0.address == "Simulation" })
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LumenDeskTests.DemoWorkspace.\(UUID().uuidString)")!
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        attempts: Int = 100
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for asynchronous state change")
    }

    @MainActor
    private func settleMainActorTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}
