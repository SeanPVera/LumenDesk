import SwiftUI
import XCTest
@testable import LumenDesk

final class DomainTests: XCTestCase {
    func testH60B0UsesThreeStreamedLampSegments() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "h60b0"))

        XCTAssertEqual(profile.layout, .lamp)
        XCTAssertEqual(profile.defaultSegmentCount, 3)
        XCTAssertFalse(profile.supportsGradient)
        XCTAssertTrue(profile.recognized)
        XCTAssertTrue(profile.appliesViaStream)
        XCTAssertTrue(profile.hasFixedSegmentCount)
        XCTAssertEqual(profile.zoneNames, ["Upper Ripple", "Middle Ambient", "Lower Daily Illumination"])
    }

    func testH612BUsesSeventyFiveZoneStripEditor() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "h612b"))

        XCTAssertEqual(profile.layout, .stripLight)
        XCTAssertEqual(profile.defaultSegmentCount, 75)
        XCTAssertEqual(profile.maximumEditorSegmentCount, 75)
        XCTAssertTrue(profile.supportsGradient)
        XCTAssertTrue(profile.recognized)
        XCTAssertTrue(profile.appliesViaStream)
        XCTAssertFalse(profile.hasFixedSegmentCount)
    }

    func testStringLightProfilesUsePhysicalBulbAndBeadCounts() throws {
        let h70c1 = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H70C1"))
        XCTAssertEqual(h70c1.layout, .stringLights)
        XCTAssertEqual(h70c1.defaultSegmentCount, 100)
        XCTAssertEqual(h70c1.stringLightStyle, .bead)
        XCTAssertEqual(h70c1.editorUnitName, "bead")
        XCTAssertTrue(h70c1.hasFixedSegmentCount)
        XCTAssertTrue(h70c1.appliesViaStream)

        let h70c2 = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "h70c2"))
        XCTAssertEqual(h70c2.defaultSegmentCount, 200)
        XCTAssertEqual(h70c2.maximumEditorSegmentCount, 200)
        XCTAssertEqual(h70c2.stringLightStyle, .bead)
        XCTAssertTrue(h70c2.hasFixedSegmentCount)

        let h70c4 = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H70C4"))
        XCTAssertEqual(h70c4.defaultSegmentCount, 200)
        XCTAssertEqual(h70c4.stringLightStyle, .bead)

        let h7021 = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H7021"))
        XCTAssertEqual(h7021.defaultSegmentCount, 30)
        XCTAssertEqual(h7021.stringLightStyle, .bulb)
        XCTAssertEqual(h7021.editorUnitName, "bulb")

        let h7028 = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H7028"))
        XCTAssertEqual(h7028.defaultSegmentCount, 15)
        XCTAssertEqual(h7028.stringLightStyle, .bulb)
        XCTAssertFalse(h7028.hasFixedSegmentCount)
    }

    func testCurtainProfileIsNotMisclassifiedAsAString() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H70B1"))

        XCTAssertEqual(profile.layout, .curtain)
        XCTAssertEqual(profile.defaultSegmentCount, 20)
        XCTAssertEqual(profile.editorUnitName, "column")
        XCTAssertTrue(profile.hasFixedSegmentCount)
        XCTAssertNil(profile.stringLightStyle)
    }

    func testChristmasStringNormalizesLegacyTwentySegmentDraft() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H70C1"))
        let legacy = GoveeSegmentState(colors: Array(
            repeating: GoveeSegmentColor(hex: 0xFF3366),
            count: 20
        ))

        let normalized = profile.normalizedEditorState(legacy)

        XCTAssertEqual(normalized.segmentCount, 100)
        XCTAssertEqual(normalized.colors.first, legacy.colors.first)
        XCTAssertEqual(normalized.colors.last, legacy.colors.last)
    }

    func testH60B0NormalizesLegacyDraftToFixedHardwareZones() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H60B0"))
        let legacy = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000),
            .init(hex: 0x0000FF)
        ], isActive: true)

        let normalized = profile.normalizedEditorState(legacy)

        XCTAssertEqual(normalized.segmentCount, 3)
        XCTAssertEqual(normalized.colors.first, legacy.colors.first)
        XCTAssertEqual(normalized.colors.last, legacy.colors.last)
        XCTAssertTrue(normalized.isActive)
    }

    @MainActor
    func testH60B0DraftDoesNotReplaceAppliedStreamHoldLayout() throws {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = LightDevice(
            id: "govee:uplighter",
            brand: .govee,
            backendID: "AA:BB:CC:DD:EE:FF",
            name: "Uplighter",
            address: "192.0.2.10",
            sku: "H60B0"
        )
        let applied = GoveeSegmentState(colors: [
            .init(hex: 0xFF6600),
            .init(hex: 0x6633FF),
            .init(hex: 0xFFF2CC)
        ])
        let draft = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000),
            .init(hex: 0x00FF00),
            .init(hex: 0x0000FF)
        ])

        manager.applySegments(device, state: applied)
        manager.storeSegmentState(draft, for: device)

        var expected = applied
        expected.isActive = true
        XCTAssertEqual(manager.segmentState(for: device), expected)
        XCTAssertEqual(manager.activeSegmentState(for: device.id), expected)
    }

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
                ),
                "lifx:luna": DeviceSnapshot(
                    isOn: true,
                    brightness: 0.72,
                    hue: 0.6,
                    saturation: 0.8,
                    kelvin: 3_500,
                    matrix: .demoLuna(brightness: 0.72)
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
        let source = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        source.enterDemoMode()
        defer { source.exitDemoMode() }

        let data = try XCTUnwrap(source.exportConfigurationData())
        let destination = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
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
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
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
