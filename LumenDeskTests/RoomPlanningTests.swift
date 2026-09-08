import XCTest
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
