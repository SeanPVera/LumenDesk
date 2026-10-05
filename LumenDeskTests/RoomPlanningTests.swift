import XCTest
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import LumenDesk

// MARK: - Name parsing

final class RoomNameParserTests: XCTestCase {

    func testReadsTheRoomOutOfCommonVendorNames() {
        let cases: [(name: String, room: String, token: String)] = [
            ("Kitchen Counter L", "Kitchen", "kitchen"),
            ("Bed Left", "Bedroom", "bed"),
            ("TV Backlight", "Living Room", "tv"),
            ("Monitor Light Bar", "Office", "monitor"),
            ("Back Porch", "Outdoor", "porch"),
            ("Hallway Downlight", "Hallway", "hall")
        ]
        for expected in cases {
            let candidate = RoomNameParser.candidate(for: expected.name)
            XCTAssertEqual(candidate?.room, expected.room, "room for \(expected.name)")
            XCTAssertEqual(candidate?.token, expected.token, "token for \(expected.name)")
        }
    }

    func testNamesWithNoRoomInThemReturnNothing() {
        for name in ["LIFX Bulb 3", "Govee H619A", "Strip 2", "", "   "] {
            XCTAssertNil(RoomNameParser.candidate(for: name), "expected no candidate for \(name)")
        }
    }

    /// A three-letter-or-longer token may match the start of a longer word, so
    /// "bed" catches "bedroom". Shorter tokens must not, or a model number
    /// containing those letters starts inventing rooms.
    func testShortTokensNeverMatchInsideAWord() {
        XCTAssertEqual(RoomNameParser.candidate(for: "Bedroom Lamp")?.room, "Bedroom")
        XCTAssertEqual(RoomNameParser.candidate(for: "Bathroom Mirror")?.room, "Bathroom")

        // "tv" is two characters, so it only matches as a whole word.
        XCTAssertNil(RoomNameParser.candidate(for: "H6TVX Strip"))
        XCTAssertEqual(RoomNameParser.candidate(for: "TV Backlight")?.token, "tv")
    }

    func testPunctuationAndCaseAreNormalised() {
        XCTAssertEqual(RoomNameParser.normalize("Kitchen-Counter_L"), "kitchen counter l")
        XCTAssertEqual(RoomNameParser.candidate(for: "KITCHEN--COUNTER")?.room, "Kitchen")
        XCTAssertEqual(RoomNameParser.candidate(for: "kitchen.counter.left")?.room, "Kitchen")
    }

    func testMultiWordTokensMatchAsAPhrase() {
        XCTAssertEqual(RoomNameParser.candidate(for: "Key Light")?.room, "Office")
        XCTAssertEqual(RoomNameParser.candidate(for: "Key Light")?.token, "key light")
    }

    /// The whole point of the parser is that a wrong guess costs one tap and a
    /// missing guess costs a whole flash cycle, so it should catch the bulk of
    /// a realistic rig.
    func testGroupsARealisticRigAndLeavesTheRestForTheFlashLoop() {
        let rig: [(id: String, name: String)] = [
            ("01", "TV Backlight"),
            ("02", "LIFX Bulb 3"),
            ("03", "Shelf Strip"),
            ("04", "Kitchen Counter L"),
            ("05", "Kitchen Counter R"),
            ("06", "Pendant"),
            ("07", "Bed Left"),
            ("08", "Bed Right"),
            ("09", "Closet"),
            ("10", "Key Light"),
            ("11", "Monitor Light Bar")
        ]

        let proposals = RoomNameParser.proposals(for: rig)
        let names = proposals.map(\.name)

        XCTAssertEqual(Set(names), ["Kitchen", "Bedroom", "Office"])
        XCTAssertEqual(proposals.first(where: { $0.name == "Kitchen" })?.lightIDs, ["04", "05"])
        XCTAssertEqual(proposals.first(where: { $0.name == "Bedroom" })?.lightIDs, ["07", "08"])
        XCTAssertEqual(proposals.first(where: { $0.name == "Office" })?.lightIDs, ["10", "11"])

        // "TV Backlight" matches Living Room on its own, which is exactly the
        // room-of-one case: a single fixture is not evidence a room exists.
        XCTAssertFalse(names.contains("Living Room"))

        let sorted = proposals.flatMap(\.lightIDs)
        XCTAssertEqual(sorted.count, 6, "six of eleven sort themselves; the rest go to the flash loop")
    }

    func testRoomOfOneIsDiscardedButTheThresholdIsAdjustable() {
        let single: [(id: String, name: String)] = [("01", "Kitchen Island")]
        XCTAssertTrue(RoomNameParser.proposals(for: single).isEmpty)
        XCTAssertEqual(RoomNameParser.proposals(for: single, minimumMembers: 1).count, 1)
    }

    /// Proposal order must come from the input, never from Dictionary
    /// iteration, or the setup screen reshuffles itself between launches.
    func testProposalOrderFollowsFirstAppearance() {
        let rig: [(id: String, name: String)] = [
            ("01", "Bed Left"), ("02", "Bed Right"),
            ("03", "Kitchen Counter L"), ("04", "Kitchen Counter R")
        ]
        XCTAssertEqual(RoomNameParser.proposals(for: rig).map(\.name), ["Bedroom", "Kitchen"])
    }
}

// MARK: - Fixture symbols

final class FixtureSymbolTests: XCTestCase {

    /// A Luna is both a matrix and segmented; the square is the more specific
    /// statement, so it has to win.
    func testMatrixBeatsSegments() {
        XCTAssertEqual(FixtureSymbol.classify(isMatrix: true, hasSegments: true), .panel)
        XCTAssertEqual(FixtureSymbol.classify(isMatrix: true, hasSegments: false), .panel)
    }

    func testSegmentedFixturesAreStrips() {
        XCTAssertEqual(FixtureSymbol.classify(isMatrix: false, hasSegments: true), .strip)
    }

    /// A fixture the catalog has never seen still has to land somewhere.
    func testAnythingElseIsABulb() {
        XCTAssertEqual(FixtureSymbol.classify(isMatrix: false, hasSegments: false), .bulb)
    }
}

// MARK: - Board layout

final class PlanLayoutTests: XCTestCase {

    private func room(_ count: Int) -> (id: UUID, fixtureCount: Int) {
        (id: UUID(), fixtureCount: count)
    }

    func testFootprintGrowsWithFixtureCount() {
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 0).width, 1)
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 1).width, 1)
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 1).height, 1)
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 3).width, 2)
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 3).height, 1)
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 4).height, 2)
        XCTAssertEqual(PlanLayout.defaultSpan(fixtureCount: 7).width, 3)
    }

    func testAutoArrangePlacesEveryRoomWithoutOverlapAndInsideTheBoard() {
        let rooms = [room(3), room(3), room(2), room(2), room(1), room(6), room(1)]
        let frames = PlanLayout.autoArrange(rooms)

        XCTAssertEqual(frames.count, rooms.count, "every room gets a frame")

        for (id, frame) in frames {
            XCTAssertGreaterThanOrEqual(frame.column, 0)
            XCTAssertGreaterThanOrEqual(frame.row, 0)
            XCTAssertLessThanOrEqual(frame.maxColumn, PlanLayout.columns,
                                     "no block may hang off the right edge")
            for (otherID, other) in frames where otherID != id {
                XCTAssertFalse(frame.intersects(other), "\(frame) overlaps \(other)")
            }
        }
    }

    /// A plan that rearranges itself between launches is a plan you have to
    /// re-learn, which would defeat the entire direction.
    func testAutoArrangeIsDeterministic() {
        let rooms = [room(4), room(2), room(1), room(3), room(2)]
        XCTAssertEqual(PlanLayout.autoArrange(rooms), PlanLayout.autoArrange(rooms))
    }

    func testAutoArrangePutsTheBiggestRoomFirst() {
        let small = room(1)
        let big = room(8)
        let frames = PlanLayout.autoArrange([small, big])
        XCTAssertEqual(frames[big.id], RoomPlanFrame(column: 0, row: 0, width: 3, height: 2))
        XCTAssertNotEqual(frames[small.id]?.column, 0, "the one-lamp room yields the origin")
    }

    func testAutoArrangeHandlesAnEmptyHome() {
        XCTAssertTrue(PlanLayout.autoArrange([]).isEmpty)
        XCTAssertEqual(PlanLayout.rowCount(for: [:]), PlanLayout.minimumRows)
    }

    func testCanPlaceRefusesOverlapsAndOutOfBounds() {
        let a = UUID(), b = UUID()
        let frames: [UUID: RoomPlanFrame] = [
            a: RoomPlanFrame(column: 0, row: 0, width: 2, height: 2),
            b: RoomPlanFrame(column: 4, row: 0, width: 2, height: 1)
        ]

        // Straight onto another room.
        XCTAssertFalse(PlanLayout.canPlace(RoomPlanFrame(column: 1, row: 1), for: b, among: frames))
        // Off the right edge.
        XCTAssertFalse(PlanLayout.canPlace(RoomPlanFrame(column: 5, row: 3, width: 2, height: 1),
                                           for: b, among: frames))
        // Negative origin.
        XCTAssertFalse(PlanLayout.canPlace(RoomPlanFrame(column: -1, row: 0), for: b, among: frames))
        // Free space is fine.
        XCTAssertTrue(PlanLayout.canPlace(RoomPlanFrame(column: 2, row: 0, width: 2, height: 1),
                                          for: b, among: frames))
        // Rows are unbounded downward, so the board can always grow.
        XCTAssertTrue(PlanLayout.canPlace(RoomPlanFrame(column: 0, row: 40), for: b, among: frames))
    }

    /// A room must be allowed to occupy the cells it already occupies, or
    /// resizing by one cell would immediately refuse itself.
    func testCanPlaceIgnoresTheRoomsOwnCurrentFrame() {
        let a = UUID()
        let frames = [a: RoomPlanFrame(column: 1, row: 1, width: 2, height: 2)]
        XCTAssertTrue(PlanLayout.canPlace(RoomPlanFrame(column: 1, row: 1, width: 3, height: 2),
                                          for: a, among: frames))
    }

    func testRowCountCoversTheLowestBlockButNeverGoesBelowTheMinimum() {
        let a = UUID()
        XCTAssertEqual(PlanLayout.rowCount(for: [a: RoomPlanFrame(column: 0, row: 0)]),
                       PlanLayout.minimumRows)
        XCTAssertEqual(PlanLayout.rowCount(for: [a: RoomPlanFrame(column: 0, row: 6, height: 2)]), 8)
    }

    func testFrameIntersectionIsEdgeExclusive() {
        let a = RoomPlanFrame(column: 0, row: 0, width: 2, height: 2)
        XCTAssertFalse(a.intersects(RoomPlanFrame(column: 2, row: 0, width: 2, height: 2)),
                       "blocks that share an edge do not overlap")
        XCTAssertFalse(a.intersects(RoomPlanFrame(column: 0, row: 2, width: 2, height: 2)))
        XCTAssertTrue(a.intersects(RoomPlanFrame(column: 1, row: 1, width: 2, height: 2)))
    }

    func testDefaultAnchorsSpreadFixturesAndStayInsideTheBlock() {
        XCTAssertTrue(PlanLayout.defaultAnchors(count: 0).isEmpty)

        let anchors = PlanLayout.defaultAnchors(count: 5)
        XCTAssertEqual(anchors.count, 5)
        for anchor in anchors {
            XCTAssertGreaterThanOrEqual(anchor.x, 0.06)
            XCTAssertLessThanOrEqual(anchor.x, 0.94)
            XCTAssertGreaterThanOrEqual(anchor.y, 0.06)
            XCTAssertLessThanOrEqual(anchor.y, 0.94)
        }
        XCTAssertEqual(anchors.map(\.x), anchors.map(\.x).sorted(), "fixtures run left to right")
        XCTAssertNotEqual(anchors[0].y, anchors[1].y, "neighbours sit in different depth bands")
    }

    func testAnchorsClampRatherThanEscapeTheBlock() {
        let anchor = PlanAnchor(x: -3, y: 9)
        XCTAssertEqual(anchor.x, 0.06, accuracy: 0.0001)
        XCTAssertEqual(anchor.y, 0.94, accuracy: 0.0001)
    }
}


final class RoomWorkspaceTests: XCTestCase {
    @MainActor
    func testRoomAggregateObservesIndividualDevicesAndIncludesStaleTargets() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let a = try XCTUnwrap(manager.devices.first)
        let b = try XCTUnwrap(manager.devices.last)
        a.brightness = 0.2
        b.brightness = 0.6
        b.isStale = true
        XCTAssertEqual(RoomOutputState.level(of: [a, b]), 0.4, accuracy: 0.001)
        let aggregate = RoomOutputState(lights: [a, b])
        var updates = 0
        let token = aggregate.objectWillChange.sink { updates += 1 }
        defer { token.cancel() }
        a.brightness = 0.8
        XCTAssertGreaterThan(updates, 0, "Device updates must invalidate the room readout")
        XCTAssertEqual(RoomOutputState.level(of: [a, b]), 0.7, accuracy: 0.001)
        // A narrower selection gets its own observer (the call sites key the
        // view's identity on its targets), and it never hears other lights.
        let narrowed = RoomOutputState(lights: [b])
        var narrowedUpdates = 0
        let narrowedToken = narrowed.objectWillChange.sink { narrowedUpdates += 1 }
        defer { narrowedToken.cancel() }
        a.brightness = 0.1
        XCTAssertEqual(narrowedUpdates, 0, "A target set must not observe lights outside it")
        b.brightness = 0.5
        XCTAssertGreaterThan(narrowedUpdates, 0)
        manager.setPower(deviceIDs: [a.id, b.id], on: true)
        XCTAssertTrue(b.isOn, "Stale lights remain eligible for a recovery command")
    }

    @MainActor
    func testRoomPowerAndBrightnessTakeOverShowsAndRestoreOtherLights() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let a = try XCTUnwrap(manager.devices.first { !$0.isStale })
        let b = try XCTUnwrap(manager.devices.last { !$0.isStale && $0.id != a.id })
        a.isOn = true
        b.brightness = 0.31
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config, scope: .all)
        XCTAssertEqual(manager.activeEffects[.all], "music-pulse")
        manager.setPower(deviceIDs: [a.id], on: false)
        manager.musicModeController.renderNowForTesting()
        XCTAssertNil(manager.activeEffects[.all])
        XCTAssertFalse(a.isOn)
        XCTAssertEqual(b.brightness, 0.31, accuracy: 0.001)
        manager.startMusicMode(configuration: config, scope: .all)
        manager.setBrightness(deviceIDs: [a.id], value: 1.4)
        manager.musicModeController.renderNowForTesting()
        XCTAssertNil(manager.activeEffects[.all])
        XCTAssertEqual(a.brightness, 1)
        XCTAssertEqual(b.brightness, 0.31, accuracy: 0.001)
        let room = try XCTUnwrap(manager.rooms.first { $0.lightIDs.contains(a.id) })
        manager.startMusicMode(configuration: config, scope: .all)
        manager.setBrightness(in: room, value: 0.42)
        XCTAssertNil(manager.activeEffects[.all])
        XCTAssertEqual(a.brightness, 0.42, accuracy: 0.001)
        manager.startMusicMode(configuration: config, scope: .all)
        manager.setPower(in: room, on: false)
        manager.confirmationCoordinator.confirmPendingRequest()
        XCTAssertNil(manager.activeEffects[.all])
        XCTAssertFalse(a.isOn)
        manager.startMusicMode(configuration: config, scope: .all)
        manager.setAllBrightness(0.25)
        XCTAssertTrue(manager.activeEffects.isEmpty)
        manager.startMusicMode(configuration: config, scope: .all)
        manager.setAllPower(on: false)
        manager.confirmationCoordinator.confirmPendingRequest()
        XCTAssertTrue(manager.activeEffects.isEmpty)
        XCTAssertTrue(manager.devices.allSatisfy { !$0.isOn })
    }

    @MainActor
    func testSelectedColorSchemeCannotReachUnselectedLightsOrAnotherRoom() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first { manager.devices(in: $0).count >= 2 })
        let a = try XCTUnwrap(manager.devices(in: room).first)
        let b = try XCTUnwrap(manager.devices(in: room).last)
        let outside = try XCTUnwrap(manager.devices.first { !room.lightIDs.contains($0.id) })
        b.isOn = false
        outside.isOn = false
        let before = b.color
        manager.applyTheme(try XCTUnwrap(LightingCatalog.themes.first),
                           deviceIDs: [a.id, outside.id], in: .room(room.id))
        XCTAssertTrue(a.isOn)
        XCTAssertFalse(b.isOn)
        XCTAssertFalse(outside.isOn)
        XCTAssertEqual(b.color, before)
        manager.undo()
        XCTAssertFalse(outside.isOn)
    }

    @MainActor
    func testRoomSelectionSurvivesEditorAndDestinationRecreation() {
        let room = LightScope.room(UUID())
        let otherRoom = LightScope.room(UUID())
        let drafts = SpectrumDraftStore()
        drafts.selections[room] = ["a", "b"]
        drafts.selections[otherRoom] = ["c"]
        _ = PlanWorkspaceView(scope: .constant(room), requestedDeviceID: .constant("a"), studioDrafts: drafts)
        _ = PlanWorkspaceView(scope: .constant(otherRoom), studioDrafts: drafts)
        _ = PlanWorkspaceView(scope: .constant(room), requestedDeviceID: .constant(nil), studioDrafts: drafts)
        XCTAssertEqual(drafts.selections[room], ["a", "b"])
        XCTAssertEqual(drafts.selections[otherRoom], ["c"])
        drafts.retainDevices(["b", "c"])
        XCTAssertEqual(drafts.selections[room], ["b"])
    }

    func testSelectionNeverExpandsAStaleSelectionToTheWholeRoom() {
        XCTAssertEqual(RoomWorkspaceSelection.targets(selected: ["gone"], available: ["a", "b"]), [])
        XCTAssertEqual(RoomWorkspaceSelection.targets(selected: [], available: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(RoomWorkspaceSelection.targets(selected: ["a", "gone"], available: ["a", "b"]), ["a"])
    }

    func testSelectionDropsRemovedFixturesWithoutInventingMembers() {
        XCTAssertEqual(RoomWorkspaceSelection.reconciled(selected: ["a", "b"], available: ["b", "c"]), ["b"])
        // A selection whose fixtures all left (moved to another room, forgotten)
        // stays until cleared, so the next edit cannot widen to the whole room.
        let removed = RoomWorkspaceSelection.reconciled(selected: ["gone"], available: ["b", "c"])
        XCTAssertEqual(removed, ["gone"])
        XCTAssertEqual(RoomWorkspaceSelection.targets(selected: removed, available: ["b", "c"]), [])
    }

    @MainActor
    func testRetainDevicesReconcilesEveryScopeInOnePublication() {
        let drafts = SpectrumDraftStore()
        let room = LightScope.room(UUID())
        drafts.selections = [.all: ["a", "b"], room: ["b", "c"]]
        var changes = 0
        let token = drafts.objectWillChange.sink { changes += 1 }
        defer { token.cancel() }
        drafts.retainDevices(["b"])
        XCTAssertEqual(drafts.selections[.all], ["b"])
        XCTAssertEqual(drafts.selections[room], ["b"])
        // luna, govee and one selections write: never one publication per scope.
        XCTAssertLessThanOrEqual(changes, 3)
        drafts.retainDevices(["x"])
        XCTAssertEqual(drafts.selections[.all], ["b"], "A dead selection waits to be cleared")
    }

    @MainActor
    func testWorkspaceSwapClearsSelectionsAndDrafts() {
        let drafts = SpectrumDraftStore()
        drafts.selections = [.all: ["live-a"], .room(UUID()): ["live-b"]]
        drafts.govee["live-a"] = GoveeSegmentState(colors: [.init(hex: 0xFF6600)])
        drafts.clearAll()
        XCTAssertTrue(drafts.selections.isEmpty)
        XCTAssertTrue(drafts.govee.isEmpty)
        XCTAssertTrue(drafts.luna.isEmpty)
        // Demo lights share no IDs with live ones, so after the swap the room
        // controls target the whole demo room instead of "0 of N selected".
        XCTAssertEqual(RoomWorkspaceSelection.targets(selected: drafts.selections[.all] ?? [],
                                                      available: ["demo-a", "demo-b"]),
                       ["demo-a", "demo-b"])
    }

    @MainActor
    func testUndoCancelsPendingDebouncedBrightness() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let device = try XCTUnwrap(manager.devices.first { !$0.isStale })
        let original = device.brightness
        manager.setBrightness(deviceIDs: [device.id], value: 0.42)
        XCTAssertEqual(device.brightness, 0.42, accuracy: 0.001)
        XCTAssertTrue(manager.pendingBrightnessDeviceIDsForTesting.contains(device.id))
        manager.undo()
        XCTAssertEqual(device.brightness, original, accuracy: 0.001)
        // The deferred send is the only thing that could overwrite the undo on
        // the wire, so its cancellation is the assertion; no clock wait needed.
        XCTAssertFalse(manager.pendingBrightnessDeviceIDsForTesting.contains(device.id),
                       "Undo must cancel the deferred brightness send")
    }

    @MainActor
    func testScheduleTakesOverAShowFromThePreShowLook() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        // A plain bulb, so restoring it is a colour rather than a matrix or zone layout.
        let room = try XCTUnwrap(manager.rooms.first { room in
            manager.devices(in: room).contains { !$0.isStale && $0.brand == .lifx && !$0.isLIFXLuna }
        })
        let light = try XCTUnwrap(manager.devices(in: room).first { !$0.isStale && $0.brand == .lifx && !$0.isLIFXLuna })
        let preShowColor = Color(red: 0.2, green: 0.4, blue: 0.6)
        light.isOn = true
        light.brightness = 0.8
        light.color = preShowColor
        var config = MusicModeConfiguration.configuration(for: .balanced)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config, scope: .room(room.id))
        XCTAssertEqual(manager.activeEffects[.room(room.id)], "music-pulse")
        // A show frame on the light, plus a slider send still in flight. The
        // room controls would stop the show themselves, so drive the
        // debounce directly to keep the show running into the schedule.
        light.color = Color(hue: 0.9, saturation: 1, brightness: 1)
        manager.previewBrightness(light, value: 0.11)
        XCTAssertTrue(manager.pendingBrightnessDeviceIDsForTesting.contains(light.id))
        manager.testSchedule(ScheduleEntry(hour: 9, minute: 0, action: .dim50), in: room)
        XCTAssertNil(manager.activeEffects[.room(room.id)], "Schedule must take over the show")
        XCTAssertEqual(light.color, preShowColor, "The action starts from the pre-show look")
        XCTAssertEqual(light.brightness, 0.5, accuracy: 0.001)
        XCTAssertFalse(manager.pendingBrightnessDeviceIDsForTesting.contains(light.id),
                       "Schedule brightness must not leave a deferred slider send")
    }

    @MainActor
    func testRunTestScheduleIsUndoable() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first { !manager.devices(in: $0).isEmpty })
        let lights = manager.devices(in: room)
        for light in lights { light.brightness = 0.3 }
        manager.testSchedule(ScheduleEntry(hour: 9, minute: 0, action: .dim75), in: room)
        XCTAssertTrue(lights.allSatisfy { abs($0.brightness - 0.75) < 0.001 })
        manager.undo()
        XCTAssertTrue(lights.allSatisfy { abs($0.brightness - 0.3) < 0.001 }, "Run Test is undoable")
    }

    @MainActor
    func testScopedCaptureKeepsSavedTopologyAndDoesNotIncludeOtherRooms() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first)
        manager.captureScene(name: "Only this room", scope: .room(room.id))
        let scene = try XCTUnwrap(manager.scenes.last)
        XCTAssertEqual(Set(scene.snapshots.keys), Set(manager.devices(in: room).map(\.id)))
        XCTAssertLessThan(scene.snapshots.count, manager.devices.count)
        for light in manager.devices(in: room) {
            XCTAssertEqual(scene.snapshots[light.id]?.segments, manager.activeSegmentState(for: light.id))
            XCTAssertEqual(scene.snapshots[light.id]?.matrix, manager.activeLIFXMatrixState(for: light.id))
        }
        manager.captureScene(name: "Legacy all-lights capture")
        XCTAssertEqual(manager.scenes.last?.snapshots.count, manager.devices.count)
    }

    @MainActor
    func testBulkColorAndWhiteTouchOnlyTheirSelectionAndCanUndo() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let lights = manager.devices.filter { !$0.isStale }
        let a = try XCTUnwrap(lights.first)
        let b = try XCTUnwrap(lights.last)
        let before = b.color.rgbComponents
        manager.setColor(deviceIDs: [a.id], color: .red)
        XCTAssertEqual(a.color.rgbComponents.r, 1, accuracy: 0.001)
        XCTAssertEqual(b.color.rgbComponents.r, before.r, accuracy: 0.001)
        XCTAssertTrue(manager.canUndo)
        let otherKelvin = b.kelvin
        manager.setKelvin(deviceIDs: [a.id], kelvin: 4200)
        XCTAssertEqual(a.kelvin, 4200)
        XCTAssertEqual(b.kelvin, otherKelvin)
        XCTAssertTrue(manager.isWhiteMode(a.id))
        manager.setColor(deviceIDs: [a.id], color: .blue)
        XCTAssertFalse(manager.isWhiteMode(a.id))
    }
}

/// Region edits must stay narrower than room-level bulk controls.
final class SpectrumRegionSelectionTests: XCTestCase {
    func testNoneAndRemovedRegionsNeverExpandToTheWholeFixture() {
        let available: Set<Int> = [1, 2, 3, 4]
        XCTAssertTrue(SpectrumRegionSelection.targets(selected: [], available: available).isEmpty)
        XCTAssertTrue(SpectrumRegionSelection.targets(selected: [99], available: available).isEmpty)
        XCTAssertEqual(SpectrumRegionSelection.targets(selected: [2, 99], available: available), [2])
        XCTAssertEqual(SpectrumRegionSelection.targets(selected: available, available: available), available)
    }

    func testExactLunaChromaKeepsDarkZonesDarkAndPreservesTheirWhitePoint() {
        let dark = LIFXMatrixColor(hue: 100, saturation: 200, brightness: 0, kelvin: 2800)
        let changed = dark.settingChroma(.blue)
        XCTAssertEqual(changed.brightness, 0)
        XCTAssertEqual(changed.kelvin, 2800)
        XCTAssertGreaterThan(changed.saturation, 65000)
        XCTAssertNotEqual(changed.hue, dark.hue)
        let lit = dark.settingBrightness(0.42)
        XCTAssertEqual(lit.settingChroma(.red).brightness, lit.brightness)
        XCTAssertEqual(lit.settingChroma(.red).kelvin, lit.kelvin)
    }

    func testLunaSelectionExcludesTheFourNonexistentCorners() {
        let corners: Set<Int> = [0, 4, 25, 29]
        let face = Set(0..<30).subtracting(corners)
        let targets = SpectrumRegionSelection.targets(selected: Set(0..<30), available: face)
        XCTAssertEqual(targets.count, 26)
        XCTAssertTrue(targets.isDisjoint(with: corners))
    }
}

/// Opt-in rendered review, separate from behavioral tests. NSHostingView renders
/// production SwiftUI in a real AppKit window; these are not mockup screenshots.
/// No LightManager.start(), UDP clients, microphone or screen capture is used.
#if os(macOS)
final class SpectrumEditorLifecycleTests: XCTestCase {
    @MainActor
    func testClosingGoveeEditorAfterShowTakeoverPreservesOutputAndKeepsDraft() async throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let light = try XCTUnwrap(manager.devices.first { manager.segmentProfile(for: $0)?.layout == .cobStrip })
        let applied = manager.segmentState(for: light)
        manager.applySegments(light, state: applied)
        var pending = applied
        pending.colors[0] = GoveeSegmentColor(color: .red, brightness: 0.23)
        let appeared = expectation(description: "Editor mounted")
        let disappeared = expectation(description: "Draft retained on close")
        var retained: GoveeSegmentState?
        let editor = GoveeSegmentEditorView(device: light, initialDraft: pending, onDraftChange: {
            retained = $0
            disappeared.fulfill()
        }).environmentObject(manager).onAppear { appeared.fulfill() }
        let host = NSHostingView(rootView: AnyView(editor))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        await fulfillment(of: [appeared], timeout: 3)

        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id != "music-pulse" })
        manager.startEffect(effect, scope: .all)
        XCTAssertNotNil(manager.animatingEffect(for: light.id))
        let outputColors = manager.segmentState(for: light).colors
        host.rootView = AnyView(EmptyView())
        await fulfillment(of: [disappeared], timeout: 3)

        XCTAssertEqual(manager.segmentState(for: light).colors, outputColors,
                       "Closing the editor must not overwrite output after a show takes ownership")
        XCTAssertEqual(retained?.colors, pending.colors, "The unapplied draft must survive navigation")
        XCTAssertNotNil(manager.animatingEffect(for: light.id))
        manager.stopAllEffects()
    }
}

final class RoomWorkspaceRenderTests: XCTestCase {
    @MainActor
    func testRenderReviewStates() async throws {
        guard ProcessInfo.processInfo.environment["LUMENDESK_RENDER_QA"] == "1" else {
            throw XCTSkip("Set LUMENDESK_RENDER_QA=1 to capture production SwiftUI views.")
        }
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        try await capture("empty-620", PlanWorkspaceView(scope: .constant(.all)), manager, width: 620, height: 700)
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first)
        let scope = LightScope.room(room.id)
        try await capture("shell-demo", LumenDeskShellView(), manager, width: 1100, height: 1000)
        try await capture("shell-620", LumenDeskShellView(), manager, width: 620, height: 1000)
        try await capture("room-all-offline", PlanWorkspaceView(scope: .constant(.all)), manager, width: 1440, height: 1100)
        try await capture("room-620", PlanWorkspaceView(scope: .constant(scope)), manager, width: 620, height: 850)
        try await capture("room-1100", PlanWorkspaceView(scope: .constant(scope)), manager, width: 1100, height: 900)
        try await capture("room-1440", PlanWorkspaceView(scope: .constant(scope)), manager, width: 1440, height: 1000)
        let selected = Set(manager.devices(in: room).prefix(2).map(\.id))
        try await capture("selection", PlanWorkspaceView(scope: .constant(scope), initialSelection: selected),
                          manager, width: 1100, height: 1000)
        let light = try XCTUnwrap(manager.devices(in: room).first)
        try await capture("fixture-inspector", PlanWorkspaceView(scope: .constant(scope), initialSelection: [light.id]),
                          manager, width: 1100, height: 1100)
        try await capture("luna-studio", LIFXLunaEditorView(device: light, initialSelection: [6, 7, 8]), manager, width: 1100, height: 950)
        try await capture("room-configuration", RoomConfigurationView(room: room), manager, width: 660, height: 850)
        try await capture("scenes", LibraryWorkspaceView(scope: .constant(scope)), manager, width: 900, height: 800)
        try await capture("music-stopped", ScrollView { MusicModeView(scope: .constant(scope)).padding(24) },
                          manager, width: 1000, height: 1100)
        try await capture("music-compact", ScrollView { MusicModeView(scope: .constant(scope)).padding(16) },
                          manager, width: 620, height: 2100)
        var config = MusicModeConfiguration.configuration(for: .ambient)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config, scope: scope, reducedMotion: true)
        try await capture("music-running-demo", ScrollView { MusicModeView(scope: .constant(scope)).padding(24) },
                          manager, width: 1000, height: 1100)
        try await capture("effect-owner", PlanWorkspaceView(scope: .constant(scope)), manager, width: 1100, height: 950)
        manager.stopAllEffects()
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id != "music-pulse" })
        manager.startEffect(effect, scope: scope)
        try await capture("dynamic-effect", PlanWorkspaceView(scope: .constant(scope)), manager, width: 1100, height: 950)
        manager.stopAllEffects()
        try await capture("room-arrangement", RoomArrangementSheet(), manager, width: 820, height: 850)
        let strip = try XCTUnwrap(manager.devices.first { manager.segmentProfile(for: $0)?.layout == .cobStrip })
        try await capture("segment-studio", GoveeSegmentEditorView(device: strip, initialSelection: [0, 1, 2]), manager, width: 1100, height: 950)
        try await capture("spectrum-segment-detail", PlanWorkspaceView(scope: .constant(.all), initialSelection: [strip.id]),
                          manager, width: 1200, height: 1200)
        try await capture("segment-compact", GoveeSegmentEditorView(device: strip), manager, width: 620, height: 850)
        let string = try XCTUnwrap(manager.devices.first { manager.segmentProfile(for: $0)?.layout == .stringLights })
        manager.applySegments(string, state: manager.segmentState(for: string))
        try await capture("dense-room-lane", SpectrumFixtureLane(light: string, selected: false,
                                                                  hasDraft: false, select: {}, edit: {}).padding(24),
                          manager, width: 400, height: 280)
        try await capture("discovery-partial", DevicesWorkspaceView(), manager, width: 850, height: 900)
        try await captureShapes(manager)
        try await capture("onboarding", OnboardingView(onFinish: {}), manager, width: 760, height: 720)
    }

    /// The Shapes wall in the Demo Lounge: the studio inline in the room at
    /// three widths, as a sheet, mid-edit with a selection, turned 90°, and
    /// while Music Mode streams panel by panel.
    @MainActor
    private func captureShapes(_ manager: LightManager) async throws {
        let lounge = try XCTUnwrap(manager.rooms.first { $0.name == "Demo Lounge" })
        let scope = LightScope.room(lounge.id)
        let wall = try XCTUnwrap(manager.devices.first { $0.brand == .nanoleaf })
        let layout = try XCTUnwrap(manager.shapes.layout(wall.id))
        try await capture("shapes-room-1440", PlanWorkspaceView(scope: .constant(scope), initialSelection: [wall.id]),
                          manager, width: 1440, height: 1500)
        try await capture("shapes-room-900", PlanWorkspaceView(scope: .constant(scope), initialSelection: [wall.id]),
                          manager, width: 900, height: 2100)
        try await capture("shapes-room-620", PlanWorkspaceView(scope: .constant(scope), initialSelection: [wall.id]),
                          manager, width: 620, height: 2400)
        let picked = Set(layout.spatialPositions(rotationDegrees: 0, axis: .leftToRight).prefix(3).map(\.panelID))
        manager.shapes.beginSession(wall.id, origin: .appliedDesign, design: try XCTUnwrap(manager.shapes.designs[wall.id]))
        manager.shapes.edit(wall.id) { $0.edit { $0.paint(NanoleafPanelColor(hue: 0.55, saturation: 0.9, intensity: 1), panels: picked) } }
        try await capture("shapes-editing", NanoleafShapesStudio(device: wall, shapes: manager.shapes, presentation: .sheet,
                                                                 initialSelection: picked),
                          manager, width: 1100, height: 1500)
        manager.shapes.endSession(wall.id)
        manager.requestShapesOrientation(90, for: wall)
        try await capture("shapes-rotated", NanoleafShapesStudio(device: wall, shapes: manager.shapes, presentation: .sheet),
                          manager, width: 1100, height: 1300)
        manager.requestShapesOrientation(0, for: wall)
        var config = MusicModeConfiguration.configuration(for: .ambient)
        config.usesSyntheticDemoPattern = true
        manager.startMusicMode(configuration: config, scope: scope, reducedMotion: true)
        try await Task.sleep(nanoseconds: 700_000_000)
        try await capture("shapes-music", PlanWorkspaceView(scope: .constant(scope), initialSelection: [wall.id]),
                          manager, width: 1100, height: 1500)
        manager.stopAllEffects()
    }

    @MainActor
    private func capture<Content: View>(_ name: String, _ content: Content, _ manager: LightManager,
                                       width: CGFloat, height: CGFloat) async throws {
        let root = content.environmentObject(manager).preferredColorScheme(.dark)
            .frame(width: width, height: height).background(Lumen.stage)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 180_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUMENDESK_RENDER_DIRECTORY"]
                            ?? NSTemporaryDirectory()).appendingPathComponent("LumenDesk-Visual-QA")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        // The connector can read job logs even without an execution workspace.
        // JPEG is a review transport; the lossless originals are CI artifacts.
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]))
        try jpeg.write(to: directory.appendingPathComponent("\(name).jpg"))
        XCTAssertGreaterThan(data.count, 1000, "Rendering produced no useful image")
    }
}

#endif
