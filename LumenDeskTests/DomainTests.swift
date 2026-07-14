import SwiftUI
import XCTest
@testable import LumenDesk

final class DomainTests: XCTestCase {
    func testSceneSerialization() throws {
        let segmentState = GoveeSegmentState(
            colors: [
                GoveeSegmentColor(red: 1, green: 0.2, blue: 0.1, brightness: 0.7),
                GoveeSegmentColor(red: 0.1, green: 0.4, blue: 1, brightness: 0.5)
            ],
            gradient: true,
            isActive: true
        )
        let scene = LightingScene(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Evening",
            snapshots: [
                "govee:desk": DeviceSnapshot(
                    isOn: true,
                    brightness: 0.65,
                    hue: 0.8,
                    saturation: 0.75,
                    kelvin: 3_200,
                    segments: segmentState
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try JSONDecoder().decode(LightingScene.self, from: JSONEncoder().encode(scene))
        XCTAssertEqual(decoded, scene)
    }

    func testRoomSerialization() throws {
        let schedule = ScheduleEntry(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            hour: 21,
            minute: 30,
            action: .dim25,
            weekdays: [2, 3, 4, 5, 6]
        )
        let room = Room(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            name: "Office",
            lightIDs: ["lifx:a", "govee:b"],
            schedules: [schedule]
        )

        let decoded = try JSONDecoder().decode(Room.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded, room)
    }

    @MainActor
    func testImportExportRoundTrip() throws {
        let source = LightManager(defaults: isolatedDefaults())
        source.enterDemoMode()
        defer { source.exitDemoMode() }

        let data = try XCTUnwrap(source.exportConfigurationData())
        let destination = LightManager(defaults: isolatedDefaults())
        XCTAssertTrue(destination.importRoomsData(data))
        XCTAssertEqual(destination.rooms, source.rooms)
        XCTAssertEqual(destination.scenes, source.scenes)
        XCTAssertEqual(destination.favoriteIDs, source.favoriteIDs)
        XCTAssertEqual(destination.favoriteRoomIDs, source.favoriteRoomIDs)
        XCTAssertEqual(destination.favoriteSceneIDs, source.favoriteSceneIDs)
        XCTAssertEqual(destination.customBrightnessPresets, source.customBrightnessPresets)
    }

    func testSegmentLayoutResizingPreservesEndpoints() {
        let red = GoveeSegmentColor(red: 1, green: 0, blue: 0)
        let blue = GoveeSegmentColor(red: 0, green: 0, blue: 1)
        var state = GoveeSegmentState(colors: [red, blue], gradient: true, isActive: true)

        state.resize(to: 3)

        XCTAssertEqual(state.segmentCount, 3)
        XCTAssertEqual(state.colors.first, red)
        XCTAssertEqual(state.colors.last, blue)
        XCTAssertEqual(state.colors[1].red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(state.colors[1].blue, 0.5, accuracy: 0.0001)
    }

    @MainActor
    func testUndoRedoSnapshotRestoration() throws {
        let manager = LightManager(defaults: isolatedDefaults())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = try XCTUnwrap(manager.devices.first)
        let originalPower = device.isOn
        let originalBrightness = device.brightness

        manager.setBrightness(device, value: 0.82)
        manager.setPower(device, on: !originalPower)
        XCTAssertTrue(manager.canUndo)

        manager.undo()
        XCTAssertEqual(device.brightness, originalBrightness, accuracy: 0.0001)
        XCTAssertEqual(device.isOn, originalPower)
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        XCTAssertEqual(device.brightness, 0.82, accuracy: 0.0001)
        XCTAssertEqual(device.isOn, !originalPower)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LumenDeskTests.\(UUID().uuidString)")!
    }

}
