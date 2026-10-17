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
    func testRoomCanvasSessionKeepsSelectionInsideTheOpenRoom() {
        let roomA = Room(name: "A", lightIDs: ["a", "b"])
        let roomB = Room(name: "B", lightIDs: ["c"])
        let devices = [
            LightDevice(id: "a", brand: .lifx, backendID: "a", name: "A", address: "test"),
            LightDevice(id: "b", brand: .govee, backendID: "b", name: "B", address: "test"),
            LightDevice(id: "c", brand: .lifx, backendID: "c", name: "C", address: "test")
        ]
        let session = RoomCanvasSessionStore()

        session.reconcile(rooms: [roomA, roomB], devices: devices)
        XCTAssertEqual(session.selectedRoomID, roomA.id)
        XCTAssertEqual(session.selectedFixtureIDs, ["a", "b"])

        session.select(roomB, devices: [devices[2]])
        XCTAssertEqual(session.selectedFixtureIDs, ["c"])
        session.reconcile(rooms: [roomA], devices: Array(devices.prefix(2)))
        XCTAssertEqual(session.selectedRoomID, roomA.id)
        XCTAssertEqual(session.selectedFixtureIDs, ["a", "b"])
    }

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
    func testObservedFixtureChangeIsVisibleUntilAcknowledged() async throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.lifxDiscovered(macHex: "001122334455", address: "192.0.2.10")
        try await Task.sleep(nanoseconds: 20_000_000)
        let device = try XCTUnwrap(manager.devices.first)

        manager.lifxDidUpdate(
            macHex: "001122334455",
            label: "Desk",
            color: LIFXHSBK(hue: 0, saturation: 0, brightness: 20_000, kelvin: 3_500),
            isOn: true
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(manager.externallyChangedDeviceIDs.contains(device.id))

        manager.lifxDidUpdate(
            macHex: "001122334455",
            label: "Desk",
            color: LIFXHSBK(hue: 30_000, saturation: 50_000, brightness: 45_000, kelvin: 4_200),
            isOn: true
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(manager.externallyChangedDeviceIDs.contains(device.id))
        XCTAssertEqual(RoomCanvasStatus.resolve([device], manager: manager), .changedElsewhere)

        manager.acknowledgeExternalChange(deviceIDs: [device.id])
        XCTAssertFalse(manager.externallyChangedDeviceIDs.contains(device.id))
    }

    @MainActor
    func testLookCaptureAndScopedRecallRestoreTheSavedFixtureState() throws {
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first)
        let target = try XCTUnwrap(manager.devices(in: room).first {
            !$0.isStale && $0.brand == .lifx && !$0.isLIFXLuna
        })
        target.isOn = true
        target.brightness = 0.37
        target.color = Color(red: 0.92, green: 0.24, blue: 0.12)
        let savedColor = target.color.lifxReportedEquivalent
        let look = try XCTUnwrap(manager.captureLook(name: "Ember", deviceIDs: [target.id]))

        target.isOn = false
        target.brightness = 0.91
        target.color = .blue
        manager.applyLook(look, deviceIDs: [target.id])

        XCTAssertTrue(target.isOn)
        XCTAssertEqual(target.brightness, 0.37, accuracy: 0.001)
        XCTAssertEqual(target.color.rgbDistance(to: savedColor), 0, accuracy: 0.001)
        XCTAssertEqual(manager.scenes.last?.name, "Ember")
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
        let outside = try XCTUnwrap(manager.devices.dropFirst().first)
        manager.createRoom(name: "Outside")
        let outsideRoom = try XCTUnwrap(manager.rooms.first { $0.name == "Outside" })
        manager.assign(lightID: outside.id, toRoom: outsideRoom.id)
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
        let outside = try XCTUnwrap(manager.devices.last)
        manager.createRoom(name: "Outside")
        let outsideRoom = try XCTUnwrap(manager.rooms.first { $0.name == "Outside" })
        manager.assign(lightID: outside.id, toRoom: outsideRoom.id)
        let scopedRoom = try XCTUnwrap(manager.rooms.first { $0.id == room.id })
        manager.captureScene(name: "Only this room", scope: .room(scopedRoom.id))
        let scene = try XCTUnwrap(manager.scenes.last)
        XCTAssertEqual(Set(scene.snapshots.keys), Set(manager.devices(in: scopedRoom).map(\.id)))
        XCTAssertLessThan(scene.snapshots.count, manager.devices.count)
        for light in manager.devices(in: scopedRoom) {
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

final class EffectOwnershipRegressionTests: XCTestCase {
    @MainActor
    func testUndoStopsRegularEffectBeforeRestoringItsBaseline() throws {
        let manager = makeManager()
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first)
        let light = try XCTUnwrap(manager.devices(in: room).first { !$0.isLIFXLuna })
        light.brightness = 0.31
        light.color = .orange
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id != "music-pulse" })
        let scope = LightScope.room(room.id)
        manager.startEffect(effect, scope: scope)
        XCTAssertNotNil(manager.animatingEffect(for: light.id))

        manager.undo()
        manager.renderEffectNowForTesting(scope: scope)
        XCTAssertNil(manager.activeEffects[scope])
        XCTAssertNil(manager.animatingEffect(for: light.id))
        XCTAssertEqual(light.brightness, 0.31, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbDistance(to: .orange), 0, accuracy: 0.0001)
    }

    @MainActor
    func testUndoStopsMusicSessionAndRestoresItsBaseline() throws {
        let manager = makeManager()
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let room = try XCTUnwrap(manager.rooms.first)
        let light = try XCTUnwrap(manager.devices(in: room).first { !$0.isLIFXLuna })
        light.brightness = 0.28
        light.color = .orange
        var configuration = MusicModeConfiguration.configuration(for: .balanced)
        configuration.usesSyntheticDemoPattern = true
        let scope = LightScope.room(room.id)
        manager.startMusicMode(configuration: configuration, scope: scope)
        manager.musicModeController.renderNowForTesting()
        manager.undo()
        manager.musicModeController.renderNowForTesting()
        XCTAssertNil(manager.activeEffects[scope])
        XCTAssertTrue(manager.musicModeController.activeScopeIDs.isEmpty)
        XCTAssertEqual(light.brightness, 0.28, accuracy: 0.0001)
        XCTAssertEqual(light.color.rgbDistance(to: .orange), 0, accuracy: 0.0001)
    }

    @MainActor
    func testRoomAssignmentCannotExpandAnExistingEffectsTargets() throws {
        let manager = makeManager()
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let firstRoom = try XCTUnwrap(manager.rooms.first)
        let outside = try XCTUnwrap(manager.devices.first { !$0.isStale && $0.brand == .govee })
        manager.createRoom(name: "Outside")
        let otherRoom = try XCTUnwrap(manager.rooms.first { $0.name == "Outside" })
        manager.assign(lightID: outside.id, toRoom: otherRoom.id)
        outside.color = .orange
        outside.brightness = 0.31
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id != "music-pulse" })
        let scope = LightScope.room(firstRoom.id)
        manager.startEffect(effect, scope: scope)
        manager.assign(lightID: outside.id, toRoom: firstRoom.id)
        for _ in 0..<5 { manager.renderEffectNowForTesting(scope: scope) }

        XCTAssertNil(manager.animatingEffect(for: outside.id))
        XCTAssertEqual(outside.brightness, 0.31, accuracy: 0.0001)
        XCTAssertEqual(outside.color.rgbDistance(to: .orange), 0, accuracy: 0.0001)
        manager.stopEffect(scope: scope)
        XCTAssertEqual(outside.brightness, 0.31, accuracy: 0.0001)
    }

    @MainActor
    func testMovedOwnedLightRetainsItsShowUntilAnotherActionTakesOver() throws {
        let manager = makeManager()
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }
        let firstRoom = try XCTUnwrap(manager.rooms.first)
        let light = try XCTUnwrap(manager.devices(in: firstRoom).first { !$0.isLIFXLuna })
        manager.createRoom(name: "Outside")
        let otherRoom = try XCTUnwrap(manager.rooms.first { $0.name == "Outside" })
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id != "music-pulse" })
        let scope = LightScope.room(firstRoom.id)
        manager.startEffect(effect, scope: scope)
        manager.assign(lightID: light.id, toRoom: otherRoom.id)
        light.brightness = 0
        for _ in 0..<5 { manager.renderEffectNowForTesting(scope: scope) }
        XCTAssertGreaterThan(light.brightness, 0, "Existing ownership is independent of subsequent room membership")
        XCTAssertEqual(manager.animatingEffect(for: light.id)?.scope, scope)
        manager.setBrightness(deviceIDs: [light.id], value: 0.42)
        manager.renderEffectNowForTesting(scope: scope)
        XCTAssertNil(manager.activeEffects[scope])
        XCTAssertEqual(light.brightness, 0.42, accuracy: 0.0001)
    }

    @MainActor
    private func makeManager() -> LightManager {
        LightManager(defaults: UserDefaults(suiteName: "LumenDeskTests.EffectOwnership.\(UUID().uuidString)")!,
                     persistenceStore: temporaryPersistenceStore())
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

final class RoomCanvasRenderTests: XCTestCase {
    @MainActor
    func testRenderReviewStates() async throws {
        guard ProcessInfo.processInfo.environment["LUMENDESK_RENDER_QA"] == "1" else {
            throw XCTSkip("Set LUMENDESK_RENDER_QA=1 to capture production SwiftUI views.")
        }
        let manager = LightManager(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                   persistenceStore: temporaryPersistenceStore())
        manager.enterDemoMode()
        defer { manager.exitDemoMode() }

        try await capture("room-canvas-620", RoomCanvasShellView(), manager, width: 620, height: 850)
        try await capture("room-canvas-1100", RoomCanvasShellView(), manager, width: 1100, height: 900)
        try await capture("room-canvas-1440", RoomCanvasShellView(), manager, width: 1440, height: 1000)
        try await capture("room-canvas-settings", NavigationStack { RoomCanvasSettingsView() },
                          manager, width: 760, height: 760)
    }

    @MainActor
    private func capture<Content: View>(_ name: String, _ content: Content, _ manager: LightManager,
                                       width: CGFloat, height: CGFloat) async throws {
        let root = content.environmentObject(manager).preferredColorScheme(.light)
            .frame(width: width, height: height).background(Lumen.canvas)
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
                            ?? NSTemporaryDirectory()).appendingPathComponent("LumenDesk-Direction-A-Visual-QA")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        let jpeg = try XCTUnwrap(bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.78]
        ))
        try jpeg.write(to: directory.appendingPathComponent("\(name).jpg"))
        XCTAssertGreaterThan(data.count, 1000, "Rendering produced no useful image")
    }
}

#endif
