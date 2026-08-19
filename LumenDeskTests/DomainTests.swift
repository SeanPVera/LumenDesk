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

    func testH60B0LightsOnlyTwoOfItsThreeZonesAtOnce() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H60B0"))

        XCTAssertEqual(profile.simultaneousZoneLimit, 2)
        XCTAssertTrue(profile.limitsSimultaneousZones)
        XCTAssertEqual(profile.zoneShortNames, ["Upper", "Middle", "Lower"])
        XCTAssertEqual(profile.zoneName(2), "Lower Daily Illumination")
        XCTAssertEqual(profile.zoneShortName(2), "Lower")
        XCTAssertEqual(profile.zoneCombinations, [[0, 1], [0, 2], [1, 2]])
    }

    func testZoneLimitSwitchesOffTheZoneLitLongest() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H60B0"))
        let allThree = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000),
            .init(hex: 0x00FF00),
            .init(hex: 0x0000FF)
        ])

        // Nothing to go on: transport order decides.
        XCTAssertEqual(profile.enforcingZoneLimit(allThree).poweredSegments, [0, 1])

        // The studio hands over the zones newest-first, so the one switched on
        // longest ago is the one that gives way.
        let withHistory = profile.enforcingZoneLimit(allThree, keeping: [2, 1])
        XCTAssertEqual(withHistory.poweredSegments, [1, 2])
        XCTAssertFalse(withHistory.colors[0].isOn)
        // The zone that went dark keeps the color it was holding.
        XCTAssertEqual(withHistory.colors[0].rgb255.r, 255)

        // A layout the lamp can already show is left alone.
        var twoLit = allThree
        twoLit.setPoweredSegments([0, 2])
        XCTAssertEqual(profile.enforcingZoneLimit(twoLit), twoLit)
    }

    func testSegmentedStripsHaveNoZoneLimit() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "H619A"))
        let state = GoveeSegmentState(colors: Array(
            repeating: GoveeSegmentColor(hex: 0x44FF88),
            count: 15
        ))

        XCTAssertNil(profile.simultaneousZoneLimit)
        XCTAssertFalse(profile.limitsSimultaneousZones)
        XCTAssertTrue(profile.zoneCombinations.isEmpty)
        XCTAssertEqual(profile.enforcingZoneLimit(state).poweredCount, 15)
    }

    func testSwitchedOffSegmentRendersDarkAndKeepsItsColor() throws {
        let lit = GoveeSegmentColor(hex: 0xFF8800, brightness: 0.5)
        let dark = lit.settingPower(false)

        XCTAssertEqual(dark.rgb255.r, 255)
        XCTAssertEqual(dark.rgb255.g, 136)
        XCTAssertEqual(dark.brightness, 0.5, accuracy: 0.0001)
        XCTAssertEqual(dark.renderedRGB255.r, 0)
        XCTAssertEqual(dark.renderedRGB255.g, 0)
        XCTAssertEqual(dark.renderedRGB255.b, 0)
        XCTAssertEqual(lit.renderedRGB255.r, 255)
        // Switched-off segments share one packet whatever colors they hold.
        XCTAssertEqual(dark.packetKey, GoveeSegmentColor(hex: 0x1122FF, isOn: false).packetKey)
        XCTAssertNotEqual(dark.packetKey, lit.packetKey)
    }

    func testSegmentStateReportsAndSetsZonePower() throws {
        var state = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000),
            .init(hex: 0x00FF00),
            .init(hex: 0x0000FF)
        ])

        XCTAssertEqual(state.poweredCount, 3)
        XCTAssertFalse(state.isFullyDark)

        state.setPower(false, at: 1)
        XCTAssertEqual(state.poweredSegments, [0, 2])

        state.setPoweredSegments([1])
        XCTAssertEqual(state.poweredSegments, [1])
        XCTAssertEqual(state.poweredCount, 1)

        state.setPoweredSegments([])
        XCTAssertTrue(state.isFullyDark)
    }

    func testBlendedColorIgnoresSwitchedOffZones() throws {
        var state = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000),
            .init(hex: 0xFF0000),
            .init(hex: 0x0000FF)
        ])
        state.setPower(false, at: 2)

        let rgb = state.blendedColor.rgbComponents
        XCTAssertEqual(rgb.r, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.b, 0, accuracy: 0.001)
    }

    func testSegmentColorArchivedBeforeZonePowerDecodesAsLit() throws {
        let legacy = Data(#"{"red":1,"green":0.5,"blue":0,"brightness":0.4}"#.utf8)

        let decoded = try JSONDecoder().decode(GoveeSegmentColor.self, from: legacy)

        XCTAssertTrue(decoded.isOn)
        XCTAssertEqual(decoded.brightness, 0.4, accuracy: 0.0001)

        let dark = decoded.settingPower(false)
        let roundTripped = try JSONDecoder().decode(GoveeSegmentColor.self,
                                                    from: JSONEncoder().encode(dark))
        XCTAssertEqual(roundTripped, dark)
        XCTAssertFalse(roundTripped.isOn)
    }

    func testSegmentPresetsCarryColorsWithoutZonePower() throws {
        let preset = GoveeSegmentPreset(
            name: "Held Power",
            stops: [GoveeSegmentColor(hex: 0xFF0000, isOn: false),
                    GoveeSegmentColor(hex: 0x0000FF, isOn: false)],
            fill: .repeating
        )

        XCTAssertTrue(preset.colors(for: 4).allSatisfy(\.isOn))
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
        // Grown to the lamp's three zones, the layout would light all of them,
        // so normalizing also trims it to the two the lamp can run — keeping
        // the colors it was holding.
        XCTAssertEqual(normalized.colors.last, legacy.colors.last?.settingPower(false))
        XCTAssertEqual(normalized.poweredSegments, [0, 1])
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
        // Two lit zones and one dark one: what the lamp can actually show.
        let applied = GoveeSegmentState(colors: [
            .init(hex: 0xFF6600),
            .init(hex: 0x6633FF),
            .init(hex: 0xFFF2CC, isOn: false)
        ])
        let draft = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000),
            .init(hex: 0x00FF00, isOn: false),
            .init(hex: 0x0000FF)
        ])

        manager.applySegments(device, state: applied)
        manager.storeSegmentState(draft, for: device)

        var expected = applied
        expected.isActive = true
        XCTAssertEqual(manager.segmentState(for: device), expected)
        XCTAssertEqual(manager.activeSegmentState(for: device.id), expected)
    }

    @MainActor
    func testApplyingUplighterLayoutStoresOnlyWhatTheLampCanLight() throws {
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

        manager.applySegments(device, state: GoveeSegmentState(colors: [
            .init(hex: 0xFF6600),
            .init(hex: 0x6633FF),
            .init(hex: 0xFFF2CC)
        ]))

        let stored = try XCTUnwrap(manager.activeSegmentState(for: device.id))
        XCTAssertEqual(stored.poweredCount, 2)
        XCTAssertEqual(stored.poweredSegments, [0, 1])
        XCTAssertEqual(manager.segmentState(for: device).poweredSegments, [0, 1])
    }

    @MainActor
    func testUplighterWithEveryZoneOffDoesNotSwitchTheLampOn() throws {
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
            sku: "H60B0",
            isOn: false
        )
        var dark = GoveeSegmentState(colors: [
            .init(hex: 0xFF6600),
            .init(hex: 0x6633FF),
            .init(hex: 0xFFF2CC)
        ])
        dark.setPoweredSegments([])

        manager.applySegments(device, state: dark)

        XCTAssertFalse(device.isOn)
        XCTAssertTrue(try XCTUnwrap(manager.activeSegmentState(for: device.id)).isFullyDark)

        // A layout that lights something still switches the lamp on.
        var lit = dark
        lit.setPoweredSegments([1, 2])
        manager.applySegments(device, state: lit)
        XCTAssertTrue(device.isOn)
    }

    @MainActor
    func testStripLayoutsKeepEverySegmentLitOnApply() throws {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = LightDevice(
            id: "govee:strip",
            brand: .govee,
            backendID: "AA:BB:CC:DD:EE:01",
            name: "Desk Strip",
            address: "192.0.2.11",
            sku: "H619A"
        )

        manager.applySegments(device, state: GoveeSegmentState(colors: Array(
            repeating: GoveeSegmentColor(hex: 0x33CCFF),
            count: 15
        )))

        XCTAssertEqual(try XCTUnwrap(manager.activeSegmentState(for: device.id)).poweredCount, 15)
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
