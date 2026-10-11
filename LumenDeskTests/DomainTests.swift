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
    func testScheduleLimitReportsRejectionAndAllowsAddingAfterDeletion() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.createRoom(name: "Office")
        let room = try XCTUnwrap(manager.rooms.first)
        for hour in 0..<LightManager.maximumSchedulesPerRoom {
            XCTAssertTrue(manager.addSchedule(ScheduleEntry(hour: hour, minute: 0, action: .turnOn), to: room.id))
        }
        let rejected = ScheduleEntry(hour: 20, minute: 0, action: .turnOff)
        XCTAssertFalse(manager.addSchedule(rejected, to: room.id))
        XCTAssertEqual(manager.schedules(for: room.id).count, LightManager.maximumSchedulesPerRoom)
        XCTAssertFalse(manager.schedules(for: room.id).contains { $0.id == rejected.id })

        manager.deleteSchedule(try XCTUnwrap(manager.schedules(for: room.id).first?.id), from: room.id)
        XCTAssertTrue(manager.addSchedule(rejected, to: room.id))
        XCTAssertTrue(manager.schedules(for: room.id).contains { $0.id == rejected.id })
        XCTAssertFalse(manager.addSchedule(ScheduleEntry(hour: 21, minute: 0, action: .turnOff), to: UUID()))
    }

    @MainActor
    func testSceneFailureRetryKeepsSuccessfulLightsOffProtectionAndOriginalVersion() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let successful = try XCTUnwrap(manager.devices.first { $0.id == "demo:2" })
        let failed = try XCTUnwrap(manager.devices.first { $0.id == "demo:4" })
        let protected = try XCTUnwrap(manager.devices.first { $0.id == "demo:0" })
        protected.isOn = true
        manager.captureScene(name: "Evening")
        var original = try XCTUnwrap(manager.scenes.last)
        original.snapshots = [
            successful.id: DeviceSnapshot(isOn: true, brightness: 0.42, hue: 0.2, saturation: 0.7),
            failed.id: DeviceSnapshot(isOn: true, brightness: 0.37, hue: 0.6, saturation: 0.8),
            protected.id: DeviceSnapshot(isOn: false, brightness: 0.1, hue: 0, saturation: 0)
        ]
        manager.updateScene(original)
        manager.captureScene(name: original.name)
        // Store another scene with the same name. Retry must use the applied
        // value and UUID, rather than looking up whichever name matches first.
        manager.applyScene(original, allowTurningOff: false, reviewed: true)
        XCTAssertEqual(manager.lastSceneResult?.failedIDs, [failed.id])
        XCTAssertEqual(manager.lastSceneResult?.skippedOffIDs, [protected.id])

        successful.brightness = 0.91
        protected.brightness = 0.77
        failed.brightness = 0.92
        failed.isStale = false
        var edited = original
        edited.name = "Renamed Evening"
        edited.snapshots[failed.id]?.brightness = 0.13
        edited.snapshots[failed.id]?.isOn = false
        // The library may change or no longer contain this version at all.
        // The duplicate captured above also has different device snapshots.
        manager.updateScene(edited)

        manager.retryLastSceneFailures()

        XCTAssertEqual(successful.brightness, 0.91, accuracy: 0.0001)
        XCTAssertEqual(protected.brightness, 0.77, accuracy: 0.0001)
        XCTAssertTrue(protected.isOn)
        XCTAssertEqual(failed.brightness, 0.37, accuracy: 0.0001)
        XCTAssertTrue(failed.isOn)
        let result = try XCTUnwrap(manager.lastSceneResult)
        XCTAssertEqual(result.scene, original)
        XCTAssertFalse(result.allowTurningOff)
        XCTAssertTrue(result.failedIDs.isEmpty)
        XCTAssertEqual(Set(result.succeededIDs), [successful.id, failed.id])
        XCTAssertEqual(result.skippedOffIDs, [protected.id])

        manager.undo()
        XCTAssertEqual(failed.brightness, 0.92, accuracy: 0.0001)
        XCTAssertEqual(successful.brightness, 0.91, accuracy: 0.0001)
        XCTAssertTrue(protected.isOn)
    }

    @MainActor
    func testSceneScopeSummaryIncludesOtherRoomsUnassignedAndUndiscoveredFixtures() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        manager.createRoom(name: "Study")
        manager.createRoom(name: "Bedroom")
        let study = try XCTUnwrap(manager.rooms.first { $0.name == "Study" })
        let bedroom = try XCTUnwrap(manager.rooms.first { $0.name == "Bedroom" })
        manager.assign(lightID: "demo:0", toRoom: study.id)
        manager.assign(lightID: "demo:1", toRoom: nil)
        manager.assign(lightID: "missing:assigned", toRoom: bedroom.id)
        let snapshot = DeviceSnapshot(isOn: true, brightness: 0.5, hue: 0.2, saturation: 0.7)
        let scene = LightingScene(name: "Evening", snapshots: [
            "demo:0": snapshot, "demo:1": snapshot,
            "missing:assigned": snapshot, "missing:unassigned": snapshot
        ])

        let summary = manager.sceneScopeSummary(scene, selectedScope: .room(study.id))

        XCTAssertEqual(summary.description, "Saved fixtures: Bedroom (1), Study (1), Unassigned (1), Undiscovered (1)")
        XCTAssertEqual(summary.outsideSelectedRoomCount, 3)
        XCTAssertEqual(summary.outsideSelectedRoomMessage, "Includes 3 saved lights outside Study.")
        XCTAssertNil(manager.sceneScopeSummary(scene).outsideSelectedRoomMessage)
        XCTAssertEqual(scene.snapshots.count, 4, "Displaying a selected room must never filter the saved scene")
    }

    @MainActor
    func testSceneScopeSummaryFollowsReassignmentWithoutChangingSavedFixtureIdentity() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        manager.createRoom(name: "Study")
        manager.createRoom(name: "Bedroom")
        let study = try XCTUnwrap(manager.rooms.first { $0.name == "Study" })
        let bedroom = try XCTUnwrap(manager.rooms.first { $0.name == "Bedroom" })
        manager.assign(lightID: "demo:0", toRoom: study.id)
        let scene = LightingScene(name: "Reading", snapshots: [
            "demo:0": DeviceSnapshot(isOn: true, brightness: 0.5, hue: 0.2, saturation: 0.7)
        ])
        XCTAssertEqual(manager.sceneScopeSummary(scene, selectedScope: .room(study.id)).outsideSelectedRoomCount, 0)

        manager.assign(lightID: "demo:0", toRoom: bedroom.id)

        let summary = manager.sceneScopeSummary(scene, selectedScope: .room(study.id))
        XCTAssertEqual(summary.description, "Saved fixtures: Bedroom (1)")
        XCTAssertEqual(summary.outsideSelectedRoomMessage, "Includes 1 saved light outside Study.")
        XCTAssertEqual(manager.availableDeviceIDs(for: scene), ["demo:0"])
        XCTAssertEqual(Set(scene.snapshots.keys), ["demo:0"])
    }

    @MainActor
    func testFavoriteShelfUpdatesAfterAddingMoreFavoritesWithoutReopeningTheView() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        manager.reconcileFavoriteOrder()
        let originalOrder = manager.favoriteOrder
        let first = FavoriteReference(kind: .light, rawID: "demo:1")
        let second = FavoriteReference(kind: .light, rawID: "demo:2")
        XCTAssertFalse(manager.isFavorite(first.rawID))
        XCTAssertFalse(manager.isFavorite(second.rawID))

        manager.toggleFavorite(first.rawID)
        manager.toggleFavorite(second.rawID)

        XCTAssertEqual(Array(manager.favoriteOrder.prefix(originalOrder.count)), originalOrder)
        XCTAssertEqual(Array(manager.favoriteOrder.suffix(2)), [first, second])

        manager.toggleFavorite(first.rawID)

        XCTAssertFalse(manager.favoriteOrder.contains(first))
        XCTAssertTrue(manager.favoriteOrder.contains(second))
        XCTAssertEqual(Array(manager.favoriteOrder.prefix(originalOrder.count)), originalOrder)
    }

    @MainActor
    func testDeletingAFavoriteRoomRemovesItsOrganizerEntryAndUndoRestoresIt() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.favoriteRooms.first)
        manager.reconcileFavoriteOrder()
        let reference = FavoriteReference(kind: .room, rawID: room.id.uuidString)
        let retainedFavorites = manager.favoriteOrder.filter { $0 != reference }
        XCTAssertTrue(manager.favoriteOrder.contains(reference))

        manager.deleteRoom(room.id)
        manager.confirmationCoordinator.confirmPendingRequest()

        XCTAssertFalse(manager.rooms.contains { $0.id == room.id })
        XCTAssertFalse(manager.favoriteOrder.contains(reference))
        XCTAssertEqual(manager.favoriteOrder, retainedFavorites)

        manager.undoDeleteRoom()

        XCTAssertTrue(manager.favoriteRooms.contains { $0.id == room.id })
        XCTAssertTrue(manager.favoriteOrder.contains(reference))
        XCTAssertEqual(Array(manager.favoriteOrder.prefix(retainedFavorites.count)), retainedFavorites)
    }

    @MainActor
    func testSavingRehearsedSceneRestoresLightingAndRetainsRevision() throws {
        let manager = LightManager(defaults: isolatedDefaults(), persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = try XCTUnwrap(manager.devices.first { $0.id == "demo:2" })
        manager.captureScene(name: "Room scene", scope: .all)
        let original = try XCTUnwrap(manager.scenes.last)
        let priorBrightness = device.brightness
        var draft = original
        draft.snapshots[device.id]?.brightness = 0.17
        manager.startSceneRehearsal(draft, deviceIDs: [device.id])
        XCTAssertEqual(device.brightness, 0.17, accuracy: 0.0001)

        manager.updateScene(draft)

        XCTAssertNil(manager.rehearsalSceneID)
        XCTAssertEqual(device.brightness, priorBrightness, accuracy: 0.0001)
        XCTAssertEqual(manager.scenes.last, draft)
        XCTAssertEqual(manager.revisions(for: original.id).first?.snapshots, original.snapshots)
        XCTAssertEqual(manager.lastActionSummary, "Saved Room scene — restore previous versions from scene History")
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

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LumenDeskTests.\(UUID().uuidString)")!
    }

}
