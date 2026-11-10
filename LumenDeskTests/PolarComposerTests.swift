import XCTest
import SwiftUI
@testable import LumenDesk

/// Look Composer draft rules, duplicate naming, Nanoleaf pairing timing and
/// the Add lights steps. Manager tests run in the isolated Sample Room, so
/// nothing reaches a real light.
final class PolarComposerTests: XCTestCase {
    func testColourRoundTripsThroughHueAndSaturation() {
        for rgb: UInt32 in [0xFF0000, 0x00FF00, 0x0000FF, 0xFF8C42, 0x2EC4B6, 0xFFFFFF] {
            let hs = LookDraftBuilder.hueSaturation(rgb)
            let back = LookDraftBuilder.rgb(hue: hs.hue, saturation: hs.saturation)
            let channels = { (v: UInt32) in [Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF)] }
            // Full-value colours survive hue/saturation exactly (±1 rounding).
            let maxChannel = channels(rgb).max() ?? 0
            guard maxChannel == 255 else { continue }
            for (a, b) in zip(channels(rgb), channels(back)) {
                XCTAssertLessThanOrEqual(abs(a - b), 1, String(format: "%06X -> %06X", rgb, back))
            }
        }
    }

    func testOnlyIncludedRowsBecomeSnapshots() {
        let rows = [
            LookDraftRow(id: "a", included: true, rgb: 0xFF0000, level: 0.5),
            LookDraftRow(id: "b", included: false, rgb: 0x00FF00, level: 0.9)
        ]
        let snaps = LookDraftBuilder.snapshots(rows, kelvins: ["a": 2700])
        XCTAssertEqual(Set(snaps.keys), ["a"])
        XCTAssertEqual(snaps["a"]?.brightness ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(snaps["a"]?.kelvin, 2700)
        XCTAssertEqual(snaps["a"]?.isOn, true)
    }

    func testUnchangedRowsKeepTheOriginalSnapshot() {
        var segments = GoveeSegmentState(colors: [GoveeSegmentColor(hex: 0xFF0000), GoveeSegmentColor(hex: 0x0000FF)])
        segments.isActive = true
        let original = LightingScene(name: "Evening", snapshots: [
            "strip": DeviceSnapshot(isOn: true, brightness: 0.4, hue: 0, saturation: 1, segments: segments),
            "bulb": DeviceSnapshot(isOn: true, brightness: 0.6, hue: 0.1, saturation: 0.8)
        ])
        let opening = [
            LookDraftRow(id: "strip", included: true, rgb: LookDraftBuilder.rgb(hue: 0, saturation: 1), level: 0.4),
            LookDraftRow(id: "bulb", included: true, rgb: LookDraftBuilder.rgb(hue: 0.1, saturation: 0.8), level: 0.6)
        ]
        var edited = opening
        edited[1].level = 0.9
        let snaps = LookDraftBuilder.snapshots(edited, kelvins: [:], original: original, originalRows: opening)
        XCTAssertEqual(snaps["strip"], original.snapshots["strip"], "An untouched row keeps its segment layout")
        XCTAssertNil(snaps["bulb"]?.segments)
        XCTAssertEqual(snaps["bulb"]?.brightness ?? 0, 0.9, accuracy: 0.001)
    }

    func testPaletteSeedingAndRepaint() {
        let lights = ["a", "b", "c"].map {
            LightDevice(id: $0, brand: .lifx, backendID: $0, name: $0, address: "0.0.0.0")
        }
        let rows = LookDraftBuilder.rows(palette: [0x111111, 0x222222], level: 0.7, lights: lights, selection: ["b"])
        XCTAssertEqual(rows.map(\.included), [false, true, false])
        XCTAssertEqual(rows.map(\.rgb), [0x111111, 0x222222, 0x111111])
        let repainted = LookDraftBuilder.repaint(rows, palette: [0xABCDEF])
        XCTAssertEqual(repainted[1].rgb, 0xABCDEF)
        XCTAssertEqual(repainted[0].rgb, 0x111111, "Excluded rows keep their colour")
    }

    func testCopyNamesNeverCollide() {
        XCTAssertEqual(LookDraftBuilder.copyName(for: "Evening", existing: ["Evening"]), "Evening copy")
        XCTAssertEqual(LookDraftBuilder.copyName(for: "Evening", existing: ["Evening", "evening copy"]), "Evening copy 2")
        XCTAssertEqual(LookDraftBuilder.copyName(for: "Evening", existing: ["Evening copy", "Evening copy 2"]), "Evening copy 3")
    }

    func testPairingRetriesOnlyWhileTheWindowIsClosedAndTimeRemains() {
        XCTAssertTrue(NanoleafPairingSchedule.shouldRetry(.pairingWindowClosed, elapsedSeconds: 7))
        XCTAssertFalse(NanoleafPairingSchedule.shouldRetry(.pairingWindowClosed, elapsedSeconds: 28))
        XCTAssertFalse(NanoleafPairingSchedule.shouldRetry(.unavailable, elapsedSeconds: 7))
        XCTAssertFalse(NanoleafPairingSchedule.shouldRetry(.unsupportedModel, elapsedSeconds: 7))
        XCTAssertEqual(NanoleafPairingSchedule.clock(4), "0:04")
        XCTAssertEqual(NanoleafPairingSchedule.clock(30), "0:30")
    }

    func testAddLightsHasThreeSteps() {
        XCTAssertEqual(AddLightsStep.allCases.count, 3)
        XCTAssertEqual(AddLightsStep.discover.caption, "Step 1 of 3 \u{00B7} Scan LAN")
    }

    @MainActor
    func testComposerSaveDuplicateAndPreviewRestore() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { !$0.isStale })
        let openingBrightness = light.brightness
        let openingOn = light.isOn
        let before = manager.scenes.count

        let snapshot = DeviceSnapshot(isOn: true, brightness: 0.23, hue: 0.6, saturation: 1)
        // Saving never changes a light.
        let saved = try XCTUnwrap(manager.saveComposedLook(name: "Test Look", snapshots: [light.id: snapshot]))
        XCTAssertEqual(manager.scenes.count, before + 1)
        XCTAssertEqual(light.brightness, openingBrightness, accuracy: 0.0001)
        XCTAssertNil(manager.rehearsalSceneID)

        let copy = try XCTUnwrap(manager.duplicateLook(saved.id))
        XCTAssertEqual(copy.name, "Test Look copy")
        XCTAssertEqual(copy.snapshots, saved.snapshots)
        XCTAssertNotEqual(copy.id, saved.id)

        // Preview shows the draft, then restores the opening state.
        let previewID = try XCTUnwrap(manager.previewComposedLook([light.id: snapshot]))
        XCTAssertEqual(manager.rehearsalSceneID, previewID)
        XCTAssertEqual(light.brightness, 0.23, accuracy: 0.0001)
        XCTAssertNotNil(manager.previewComposedLook([light.id: DeviceSnapshot(isOn: true, brightness: 0.5, hue: 0.2, saturation: 1)],
                                                    updating: previewID))
        XCTAssertEqual(light.brightness, 0.5, accuracy: 0.0001)
        manager.stopSceneRehearsal(restore: true)
        XCTAssertEqual(light.brightness, openingBrightness, accuracy: 0.0001)
        XCTAssertEqual(light.isOn, openingOn)
        // A stale preview id is refused and touches nothing.
        XCTAssertNil(manager.previewComposedLook([light.id: snapshot], updating: previewID))
        XCTAssertEqual(light.brightness, openingBrightness, accuracy: 0.0001)

        // Editing replaces the Look in place.
        let edited = try XCTUnwrap(manager.saveComposedLook(name: "Renamed", snapshots: [light.id: snapshot], replacing: saved.id))
        XCTAssertEqual(edited.id, saved.id)
        XCTAssertEqual(manager.scenes.first { $0.id == saved.id }?.name, "Renamed")
    }

    // MARK: Review follow-ups

    func testLevelOnlyEditKeepsSpatialPayloadAndKelvin() {
        var segments = GoveeSegmentState(colors: [GoveeSegmentColor(hex: 0xFF0000), GoveeSegmentColor(hex: 0x0000FF)])
        segments.isActive = true
        let original = LightingScene(name: "Evening", snapshots: [
            "strip": DeviceSnapshot(isOn: true, brightness: 0.4, hue: 0, saturation: 1, kelvin: 2200, segments: segments)
        ])
        let opening = [LookDraftRow(id: "strip", included: true, rgb: LookDraftBuilder.rgb(hue: 0, saturation: 1), level: 0.4)]
        var edited = opening
        edited[0].level = 0.8
        let snap = LookDraftBuilder.snapshots(edited, kelvins: ["strip": 6500], original: original, originalRows: opening)["strip"]
        XCTAssertEqual(snap?.segments, segments, "A level-only edit keeps the segment layout")
        XCTAssertEqual(snap?.kelvin, 2200, "A level-only edit keeps the saved Kelvin, not the live one")
        XCTAssertEqual(snap?.brightness ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(snap?.isOn, true)
    }

    func testColourEditReplacesTheSpatialPayload() {
        var segments = GoveeSegmentState(colors: [GoveeSegmentColor(hex: 0xFF0000)])
        segments.isActive = true
        let original = LightingScene(name: "Evening", snapshots: [
            "strip": DeviceSnapshot(isOn: true, brightness: 0.4, hue: 0, saturation: 1, segments: segments)
        ])
        let opening = [LookDraftRow(id: "strip", included: true, rgb: 0xFF0000, level: 0.4)]
        var edited = opening
        edited[0].rgb = 0x00FF00
        let snap = LookDraftBuilder.snapshots(edited, kelvins: [:], original: original, originalRows: opening)["strip"]
        XCTAssertNil(snap?.segments, "A new colour is a solid colour by design")
        XCTAssertEqual(snap?.hue ?? 0, 1.0 / 3.0, accuracy: 0.01)
    }

    func testSavedSnapshotsWithoutARowSurviveAndExcludedRowsDrop() {
        let away = DeviceSnapshot(isOn: true, brightness: 0.3, hue: 0.5, saturation: 0.5)
        let original = LightingScene(name: "Evening", snapshots: [
            "here": DeviceSnapshot(isOn: true, brightness: 0.6, hue: 0.1, saturation: 0.8),
            "dropped": DeviceSnapshot(isOn: true, brightness: 0.6, hue: 0.1, saturation: 0.8),
            "undiscovered": away
        ])
        let opening = [
            LookDraftRow(id: "here", included: true, rgb: LookDraftBuilder.rgb(hue: 0.1, saturation: 0.8), level: 0.6),
            LookDraftRow(id: "dropped", included: true, rgb: LookDraftBuilder.rgb(hue: 0.1, saturation: 0.8), level: 0.6)
        ]
        var edited = opening
        edited[1].included = false
        let snaps = LookDraftBuilder.snapshots(edited, kelvins: [:], original: original, originalRows: opening)
        XCTAssertEqual(snaps["undiscovered"], away, "A fixture with no row keeps its saved snapshot")
        XCTAssertNil(snaps["dropped"], "Unchecking a row removes it from the Look")
        XCTAssertNotNil(snaps["here"])
    }

    func testScopeOnlyFiltersRowsAndHiddenRowsStillSave() {
        let rows = [
            LookDraftRow(id: "desk", included: true, rgb: 0xFF0000, level: 0.5),
            LookDraftRow(id: "hall", included: true, rgb: 0x00FF00, level: 0.5),
            LookDraftRow(id: "porch", included: false, rgb: 0x0000FF, level: 0.5)
        ]
        let room: Set<String> = ["desk"]
        XCTAssertEqual(rows.filter { LookDraftBuilder.isVisible($0, allRooms: false, roomLightIDs: room) }.map(\.id), ["desk"])
        XCTAssertEqual(rows.filter { LookDraftBuilder.isVisible($0, allRooms: true, roomLightIDs: room) }.count, 3)
        XCTAssertEqual(LookDraftBuilder.hiddenIncludedCount(rows, allRooms: false, roomLightIDs: room), 1)
        XCTAssertEqual(LookDraftBuilder.hiddenIncludedCount(rows, allRooms: true, roomLightIDs: room), 0)
        // This room hides "hall" but saving keeps it in the Look.
        XCTAssertEqual(Set(LookDraftBuilder.snapshots(rows, kelvins: [:]).keys), ["desk", "hall"])
    }

    func testNewLookOnlyIncludesTheOpenRoom() {
        let lights = ["desk", "lamp", "hall"].map {
            LightDevice(id: $0, brand: .lifx, backendID: $0, name: $0, address: "0.0.0.0")
        }
        let seeded = LookDraftBuilder.rows(palette: [0x111111], level: 0.6, lights: lights, selection: [])
        let limited = LookDraftBuilder.limitIncluded(seeded, to: ["desk", "lamp"])
        XCTAssertEqual(limited.map(\.included), [true, true, false])
        XCTAssertEqual(limited.map(\.id), ["desk", "lamp", "hall"], "Other rooms keep a row, excluded")
    }

    func testSidebarLookPicksTheOpenRoomOrTheRoomHoldingMostOfIt() {
        let office = Room(name: "Office", lightIDs: ["desk", "lamp"])
        let lounge = Room(name: "Lounge", lightIDs: ["sofa", "tv", "shelf"])
        let hall = Room(name: "Hall", lightIDs: ["hall"])
        let rooms = [office, lounge, hall]
        let snap = DeviceSnapshot(isOn: true, brightness: 0.5, hue: 0, saturation: 0)
        let mixed = LightingScene(name: "Mixed", snapshots: ["lamp": snap, "sofa": snap, "tv": snap])
        XCTAssertEqual(LookDraftBuilder.room(for: mixed, rooms: rooms, preferring: office.id)?.id, office.id,
                       "The open room wins when the Look covers any of it")
        XCTAssertEqual(LookDraftBuilder.room(for: mixed, rooms: rooms, preferring: hall.id)?.id, lounge.id,
                       "Otherwise the room with most of the Look's fixtures")
        let orphan = LightingScene(name: "Gone", snapshots: ["nowhere": snap])
        XCTAssertNil(LookDraftBuilder.room(for: orphan, rooms: rooms, preferring: office.id))
    }

    func testPairingAddressIsValidatedBeforeTheCountdown() {
        XCTAssertNotNil(NanoleafPairingSchedule.endpoint(host: "192.0.2.10", port: "16021"))
        XCTAssertNotNil(NanoleafPairingSchedule.endpoint(host: " 192.0.2.10 ", port: " 16021 "))
        XCTAssertNil(NanoleafPairingSchedule.endpoint(host: "http://192.0.2.10/", port: "16021"))
        XCTAssertNil(NanoleafPairingSchedule.endpoint(host: "localhost", port: "16021"))
        XCTAssertNil(NanoleafPairingSchedule.endpoint(host: "", port: "16021"))
        XCTAssertNil(NanoleafPairingSchedule.endpoint(host: "192.0.2.10", port: "abc"))
        XCTAssertNil(NanoleafPairingSchedule.endpoint(host: "192.0.2.10", port: "70000"))
    }

    @MainActor
    func testMenuSheetsReplaceSiblingsAndPrevNextMovesSelection() {
        let session = RoomCanvasSessionStore()
        session.present(.looks)
        XCTAssertTrue(session.showingLooks)
        XCTAssertNil(session.pendingSheet)

        let lookID = UUID()
        session.present(.composer, editingLook: lookID, handoffDelay: 0.05)
        XCTAssertFalse(session.showingLooks, "The sibling sheet is dismissed first")
        XCTAssertFalse(session.showingComposer)
        XCTAssertEqual(session.pendingSheet, .composer)
        let shown = expectation(description: "composer follows the dismissal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { shown.fulfill() }
        wait(for: [shown], timeout: 2)
        XCTAssertTrue(session.showingComposer)
        XCTAssertEqual(session.editingLookID, lookID)
        XCTAssertEqual(session.presentedSheet, .composer)

        session.present(.composer)
        XCTAssertTrue(session.showingComposer, "Presenting the open sheet again is a no-op")

        session.openLightPage("lamp")
        XCTAssertEqual(session.editorDeviceID, "lamp")
        XCTAssertEqual(session.selectedFixtureIDs, ["lamp"])
    }
}
