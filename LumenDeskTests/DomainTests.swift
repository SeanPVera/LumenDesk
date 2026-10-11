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

    func testH6062GlideWallLightIsAnAdjustableDurableWallLight() throws {
        let profile = try XCTUnwrap(GoveeSegmentProfile.detect(sku: "h6062"))

        XCTAssertEqual(profile.layout, .wallLight)
        XCTAssertEqual(profile.layout.displayName, "Glide wall light")
        XCTAssertEqual(profile.defaultSegmentCount, 28, "the controller's addressable zones, not its pieces")
        XCTAssertEqual(profile.editorUnitName, "segment")
        XCTAssertFalse(profile.supportsGradient)
        XCTAssertTrue(profile.recognized)
        XCTAssertFalse(profile.appliesViaStream)
        XCTAssertFalse(profile.hasFixedSegmentCount, "kits ship with different piece counts")
        XCTAssertNil(profile.simultaneousZoneLimit)
        XCTAssertNil(profile.stringLightStyle)
        // Neighbouring Glide SKUs are different products and stay unrecognized.
        XCTAssertNil(GoveeSegmentProfile.detect(sku: "H6061"))
        XCTAssertNil(GoveeSegmentProfile.detect(sku: "H6063"))
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

    /// The durable write has to leave the fixture showing exactly the layout it
    /// was given. Firmware keeps the per-segment brightness it was last sent,
    /// so a fully lit layout applied over a dimmed one used to inherit the old
    /// dimming with nothing able to clear it.
    func testDurablePacketsAlwaysWritePerSegmentBrightness() {
        let allLit = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000), .init(hex: 0x00FF00), .init(hex: 0x0000FF)
        ], gradient: false)
        XCTAssertTrue(allLit.colors.allSatisfy { $0.brightnessPercent == 100 })

        let packets = allLit.durableSegmentPackets(supportsGradient: false)
        // Three colour packets plus one brightness packet covering all three.
        XCTAssertEqual(packets.count, 4)
        let brightness = packets.filter { $0[1] == 0x05 && $0[3] == 0x02 }
        XCTAssertEqual(brightness.count, 1, "an all-100% layout still has to state its brightness")
        XCTAssertEqual(brightness.first?[4], 100)
    }

    func testDurablePacketsGroupMixedBrightnessAndLeadWithGradient() {
        let mixed = GoveeSegmentState(colors: [
            .init(hex: 0xFF0000, brightness: 1.0),
            .init(hex: 0xFF0000, brightness: 0.5),
            .init(hex: 0x0000FF, brightness: 0.5)
        ], gradient: true)

        let withGradient = mixed.durableSegmentPackets(supportsGradient: true)
        let withoutGradient = mixed.durableSegmentPackets(supportsGradient: false)
        XCTAssertEqual(withGradient.count, withoutGradient.count + 1)
        XCTAssertEqual(withGradient.first?[1], 0xA3, "the gradient toggle leads the batch")

        // Two colours and two distinct levels, so two of each.
        let colours = withoutGradient.filter { $0[1] == 0x05 && $0[3] == 0x01 }
        let levels = withoutGradient.filter { $0[1] == 0x05 && $0[3] == 0x02 }
        XCTAssertEqual(colours.count, 2)
        XCTAssertEqual(levels.count, 2)
        XCTAssertEqual(Set(levels.map { $0[4] }), [100, 50])
    }

    @MainActor
    func testRehearsingASceneAppliesTheSameSegmentLayoutApplyingItWould() throws {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }

        // "Desk COB Strip" — a Govee H619A, so a real segmented profile.
        let strip = try XCTUnwrap(manager.devices.first { $0.brand == .govee && $0.sku == "H619A" })
        let layout = GoveeSegmentState(
            colors: [
                GoveeSegmentColor(red: 1, green: 0, blue: 0),
                GoveeSegmentColor(red: 0, green: 1, blue: 0),
                GoveeSegmentColor(red: 0, green: 0, blue: 1)
            ],
            gradient: true,
            isActive: true
        )
        let hsb = strip.color.hsbComponents
        let scene = LightingScene(name: "Painted Strip", snapshots: [
            strip.id: DeviceSnapshot(
                isOn: true,
                brightness: 0.42,
                hue: hsb.h,
                saturation: hsb.s,
                kelvin: strip.kelvin,
                segments: layout
            )
        ])

        // Rehearsal is a preview of applying, so it has to put the same thing
        // on the light. It used to carry its own copy of the per-device logic,
        // which had lost the segment branch entirely: rehearsing a scene that
        // captured a layout previewed one blended wash and never sent Govee a
        // brightness at all.
        manager.startSceneRehearsal(scene, deviceIDs: [strip.id])

        let rehearsed = try XCTUnwrap(manager.activeSegmentState(for: strip.id))
        XCTAssertEqual(rehearsed.colors, layout.colors)
        XCTAssertEqual(rehearsed.gradient, layout.gradient)
        XCTAssertEqual(strip.brightness, 0.42, accuracy: 0.0001)
        XCTAssertEqual(manager.rehearsalSceneID, scene.id)

        // Ending the rehearsal puts the light back where it started.
        manager.stopSceneRehearsal(restore: true)
        XCTAssertNil(manager.rehearsalSceneID)
    }

    @MainActor
    func testAFailedConfigurationExportIsReportedRatherThanSwallowed() throws {
        let manager = LightManager(
            defaults: isolatedDefaults(),
            persistenceStore: temporaryPersistenceStore()
        )

        // A directory that does not exist stands in for the read-only volume or
        // unwritable folder a user can pick in the save panel. The write used to
        // go out through `try?`, so a configuration that never landed looked
        // exactly like one that did.
        let unwritable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/LumenDesk.json")
        XCTAssertFalse(manager.exportConfiguration(to: unwritable))
        XCTAssertNotNil(manager.commandError)
        XCTAssertTrue(try XCTUnwrap(manager.commandError).contains("Export failed"))

        let writable = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumenDeskTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: writable) }
        XCTAssertTrue(manager.exportConfiguration(to: writable))
        XCTAssertTrue(FileManager.default.fileExists(atPath: writable.path))
        XCTAssertEqual(manager.lastActionSummary?.hasPrefix("Configuration exported"), true)
    }

    @MainActor
    func testRepeatedIdentifyRestoresTheOriginalLookInsteadOfTheTemporaryLook() async throws {
        let delay = IdentificationDelay()
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore(),
                                   identifySleep: { _ in await delay.wait() })
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { $0.brand == .lifx && !$0.isLIFXLuna })
        light.isOn = false
        light.brightness = 0.3
        light.color = .orange
        let originalColor = light.color

        manager.identify(light)
        await waitUntilState { await delay.pendingCount == 1 }
        manager.identify(light)
        await waitUntilState { await delay.pendingCount == 2 }
        await delay.release()
        await waitUntilState { manager.identifyingDeviceIDsForTesting.isEmpty }

        XCTAssertFalse(light.isOn)
        XCTAssertEqual(light.brightness, 0.3, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbDistance(to: originalColor), 0, accuracy: 0.0001)
    }

    @MainActor
    func testSceneTakeoverCancelsIdentificationRestoration() async throws {
        let delay = IdentificationDelay()
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore(),
                                   identifySleep: { _ in await delay.wait() })
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { $0.brand == .lifx && !$0.isLIFXLuna })
        manager.identify(light)
        await waitUntilState { await delay.pendingCount == 1 }
        let scene = LightingScene(name: "New look", snapshots: [light.id: .init(
            isOn: true, brightness: 0.42, hue: 0.65, saturation: 0.9, kelvin: 3500)])
        manager.applyScene(scene, allowTurningOff: true, reviewed: true)
        let appliedColor = light.color
        await delay.release()
        await settleStateTasks()

        XCTAssertTrue(manager.identifyingDeviceIDsForTesting.isEmpty)
        XCTAssertEqual(light.brightness, 0.42, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbDistance(to: appliedColor), 0, accuracy: 0.0001)
    }

    @MainActor
    func testDemoEntryCancelsIdentificationBeforeSavingTheLiveWorkspace() async throws {
        let delay = IdentificationDelay()
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore(),
                                   identifySleep: { _ in await delay.wait() })
        manager.goveeDiscovered(deviceID: "LIVE", address: "192.0.2.1", sku: nil)
        await waitUntilState { manager.devices.count == 1 }
        let light = try XCTUnwrap(manager.devices.first)
        light.isOn = false
        light.brightness = 0.27
        light.color = .orange
        manager.identify(light)
        await waitUntilState { await delay.pendingCount == 1 }
        manager.enterDemoMode()
        XCTAssertTrue(manager.identifyingDeviceIDsForTesting.isEmpty)
        XCTAssertFalse(light.isOn)
        await delay.release()
        manager.exitDemoMode()
        await settleStateTasks()
        XCTAssertTrue(manager.devices.first === light)
        XCTAssertFalse(light.isOn)
        XCTAssertEqual(light.brightness, 0.27, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbDistance(to: .orange), 0, accuracy: 0.0001)
    }

    @MainActor
    func testDemoResetAndExitCancelPendingIdentificationTasks() async throws {
        let delay = IdentificationDelay()
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore(),
                                   identifySleep: { _ in await delay.wait() })
        manager.enterDemoMode()
        let first = try XCTUnwrap(manager.devices.first { $0.brand == .lifx && !$0.isLIFXLuna })
        manager.identify(first)
        await waitUntilState { await delay.pendingCount == 1 }
        manager.resetDemoMode()
        XCTAssertTrue(manager.identifyingDeviceIDsForTesting.isEmpty)
        let replacement = try XCTUnwrap(manager.devices.first { $0.id == first.id })
        manager.identify(replacement)
        await waitUntilState { await delay.pendingCount == 2 }
        manager.exitDemoMode()
        await delay.release()
        await settleStateTasks()
        XCTAssertTrue(manager.devices.isEmpty)
        XCTAssertTrue(manager.identifyingDeviceIDsForTesting.isEmpty)
        XCTAssertFalse(manager.commandStates.keys.contains { $0.hasPrefix("demo:") })
    }

    @MainActor
    func testManualTakeoverEndsSustainedIdentification() async throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { $0.brand == .lifx && !$0.isLIFXLuna })
        manager.beginSustainedIdentify(light)
        await settleStateTasks()
        XCTAssertTrue(manager.isHoldingIdentify)
        manager.setBrightness(light, value: 0.45)
        await settleStateTasks()
        XCTAssertFalse(manager.isHoldingIdentify)
        XCTAssertEqual(light.brightness, 0.45, accuracy: 0.0001)
    }

    @MainActor
    func testEditingAfterUndoClearsRedoAndStartsANewUndoBoundary() throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore(),
                                   changeClock: { now })
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { !$0.isStale })
        manager.setBrightness(light, value: 0.4)
        now = now.addingTimeInterval(2)
        manager.setBrightness(light, value: 0.6)
        manager.undo()
        XCTAssertEqual(light.brightness, 0.4, accuracy: 0.0001)
        XCTAssertTrue(manager.canRedo)

        manager.setBrightness(light, value: 0.8)
        XCTAssertFalse(manager.canRedo)
        manager.redo()
        XCTAssertEqual(light.brightness, 0.8, accuracy: 0.0001)
        manager.undo()
        XCTAssertEqual(light.brightness, 0.4, accuracy: 0.0001,
                       "The post-Undo edit must not merge into the older undo entry")
    }

    @MainActor
    func testSceneRetryTargetsOnlyFailedLightsAndUsesSceneIdentity() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let available = manager.devices.filter { !$0.isStale && $0.brand != .nanoleaf }
        let first = try XCTUnwrap(available.first)
        let second = try XCTUnwrap(available.last)
        first.brightness = 0.2
        second.brightness = 0.4
        manager.captureScene(name: "Retry this scene")
        let scene = try XCTUnwrap(manager.scenes.last)
        second.isStale = true
        manager.applyScene(scene, allowTurningOff: false, reviewed: true)
        XCTAssertTrue(try XCTUnwrap(manager.lastSceneResult).failedIDs.contains(second.id))
        first.brightness = 0.83
        second.isStale = false
        second.brightness = 0.9
        // Renaming must not make the remembered scene disappear from retry.
        manager.renameScene(scene.id, to: "Renamed")
        manager.retryLastSceneFailures()
        XCTAssertEqual(first.brightness, 0.83, accuracy: 0.0001)
        XCTAssertEqual(second.brightness, 0.4, accuracy: 0.0001)
        XCTAssertEqual(manager.lastSceneResult?.sceneID, scene.id)
        XCTAssertEqual(manager.lastSceneResult?.sceneName, "Renamed")
        XCTAssertEqual(manager.lastSceneResult?.allowTurningOff, false)
    }

    @MainActor
    func testSceneRetryPreservesTheOriginalSkipOffPolicy() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let lights = manager.devices.filter { !$0.isStale && $0.brand != .nanoleaf }
        let first = try XCTUnwrap(lights.first)
        let second = try XCTUnwrap(lights.last)
        first.isOn = true
        second.isOn = true
        manager.captureScene(name: "Skip off")
        let scene = try XCTUnwrap(manager.scenes.last)
        second.isStale = true
        manager.applyScene(scene, allowTurningOff: false, reviewed: true)
        var edited = scene
        edited.snapshots[second.id]?.isOn = false
        manager.updateScene(edited)
        second.isStale = false
        manager.retryLastSceneFailures()
        XCTAssertTrue(second.isOn, "Retry must not turn off a light when the original apply prohibited that")
        XCTAssertTrue(try XCTUnwrap(manager.lastSceneResult).skippedOffIDs.contains(second.id))
    }

    @MainActor
    func testSceneRetryStillAttemptsAnOfflineLightWithoutStoppingAnotherRoomsShow() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let firstRoom = try XCTUnwrap(manager.rooms.first)
        let failed = try XCTUnwrap(manager.devices.first { $0.brand == .govee && !firstRoom.lightIDs.contains($0.id) })
        failed.brightness = 0.41
        manager.captureScene(name: "Retry offline")
        let scene = try XCTUnwrap(manager.scenes.last)
        failed.isStale = true
        manager.applyScene(scene, allowTurningOff: false, reviewed: true)
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id != "music-pulse" })
        let scope = LightScope.room(firstRoom.id)
        manager.startEffect(effect, scope: scope)
        failed.brightness = 0.9
        manager.retryLastSceneFailures()
        XCTAssertEqual(failed.brightness, 0.41, accuracy: 0.0001,
                       "A retry must try the failed target even before it answers a refresh")
        XCTAssertEqual(manager.activeEffects[scope], effect.id)
        XCTAssertEqual(try XCTUnwrap(manager.lastSceneResult).failedIDs, [failed.id])
    }

    @MainActor
    func testRecoveredDeviceUpdatesPublishedAndConfirmedState() async throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.goveeDiscovered(deviceID: "RECOVER", address: "192.0.2.2", sku: nil)
        await waitUntilState { manager.devices.count == 1 }
        let light = try XCTUnwrap(manager.devices.first)
        manager.retry(light)
        manager.goveeDidUpdate(deviceID: "RECOVER", isOn: false, brightness: 42,
                               r: 255, g: 0, b: 0, kelvin: 3500)
        await waitUntilState { !manager.commandPendingIDs.contains(light.id) }
        XCTAssertFalse(light.isOn)
        XCTAssertEqual(light.brightness, 0.42, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbComponents.r, 1, accuracy: 0.0001)
        XCTAssertEqual(manager.confirmedStates[light.id]?.isOn, false)
    }

    @MainActor
    func testDirectGoveeStateCallbacksBoundExtremeNumbersBeforePublication() async throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.goveeDiscovered(deviceID: "BOUNDS", address: "192.0.2.3", sku: nil)
        await waitUntilState { manager.devices.count == 1 }
        let light = try XCTUnwrap(manager.devices.first)
        manager.goveeDidUpdate(deviceID: "BOUNDS", isOn: true, brightness: Int.max,
                               r: Int.max, g: Int.min, b: Int.max, kelvin: Int.max)
        await settleStateTasks()
        XCTAssertEqual(light.brightness, 1)
        XCTAssertEqual(Int(light.brightness * 100), 100)
        XCTAssertEqual(light.kelvin, 9000)
        XCTAssertEqual(light.color.rgbComponents.r, 1, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbComponents.g, 0, accuracy: 0.0001)
        manager.goveeDidUpdate(deviceID: "BOUNDS", isOn: false, brightness: Int.min,
                               r: Int.min, g: Int.max, b: Int.min, kelvin: Int.min)
        await settleStateTasks()
        XCTAssertEqual(light.brightness, 0)
        XCTAssertEqual(Int(light.brightness * 100), 0)
        XCTAssertEqual(try XCTUnwrap(manager.confirmedStates[light.id]).brightness, 0)
    }

    @MainActor
    func testSolarPreferenceSettersBoundExtremeProgrammaticValues() {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        manager.setSunriseTime(hour: Int.max, minute: Int.min)
        manager.setSunsetTime(hour: Int.min, minute: Int.max)
        XCTAssertEqual(manager.sunriseHour, 23)
        XCTAssertEqual(manager.sunriseMinute, 0)
        XCTAssertEqual(manager.sunsetHour, 0)
        XCTAssertEqual(manager.sunsetMinute, 59)
    }

    @MainActor
    func testProgrammaticBrightnessAndWhiteCommandsBoundValuesBeforePublication() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { $0.brand == .lifx && !$0.isLIFXLuna })
        manager.setBrightness(light, value: .nan)
        XCTAssertEqual(light.brightness, 0)
        manager.previewBrightness(light, value: .infinity)
        XCTAssertEqual(light.brightness, 0)
        manager.commitBrightness(light, value: -Double.greatestFiniteMagnitude)
        XCTAssertEqual(light.brightness, 0)
        manager.setKelvin(light, kelvin: Int.min)
        XCTAssertEqual(light.kelvin, 1200)
        manager.setKelvin(light, kelvin: Int.max)
        XCTAssertEqual(light.kelvin, 9000)
    }

    @MainActor
    private func waitUntilState(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("State transition did not complete")
    }

    @MainActor
    private func settleStateTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LumenDeskTests.\(UUID().uuidString)")!
    }

}

private actor IdentificationDelay {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var pendingCount: Int { continuations.count }

    func wait() async {
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
