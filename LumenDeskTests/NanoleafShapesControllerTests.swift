import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LumenDesk

/// The Shapes controller wired to a real `NanoleafClient` and the fake
/// controller, the same way LightManager wires it.
@MainActor
final class NanoleafShapesControllerTests: XCTestCase {
    private var fake: FakeShapesController!
    private var datagrams: RecordingDatagrams!
    private var client: NanoleafClient!
    private var shapes: NanoleafShapesController!
    private var live = true
    private var reads = 0
    private var lastInfo: NanoleafInfo?
    private var released: [String] = []
    private let deviceID = "nanoleaf:\(FakeShapesController.serial)"
    private let serial = FakeShapesController.serial

    override func setUp() async throws {
        fake = FakeShapesController()
        datagrams = RecordingDatagrams()
        FakeShapesURLProtocol.controller = fake
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeShapesURLProtocol.self]
        client = NanoleafClient(credentials: InMemoryShapesCredentials(), session: URLSession(configuration: configuration),
                                listensForEvents: false, datagrams: datagrams, resolver: FixedResolver(address: "192.0.2.44"))
        shapes = NanoleafShapesController(client: client)
        live = true
        reads = 0
        lastInfo = nil
        released = []
        shapes.isLive = { [weak self] in self?.live ?? false }
        let id = deviceID
        client.onUpdate = { [weak self] _, info in
            guard let self else { return }
            if let owner = self.shapes.didRead(deviceID: id, info: info) { self.released.append(owner) }
            self.lastInfo = info
            self.reads += 1
        }
        client.onOperationFailure = { [weak self] _, operation, error in self?.shapes.didFail(deviceID: id, operation: operation, error: error) }
        client.onWriteAccepted = { [weak self] _, operation in self?.shapes.didAccept(deviceID: id, operation: operation) }
        client.onStreamStatus = { [weak self] _, status in self?.shapes.didChangeStream(deviceID: id, status: status) }
        try await client.pair(endpoint: fake.endpoint)
    }

    override func tearDown() async throws {
        let deadline = Date().addingTimeInterval(1)
        while client.hasWork(serial), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        client.pause()
        FakeShapesURLProtocol.controller = nil
    }

    private func settle(file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        try? await Task.sleep(nanoseconds: 5_000_000)
        while client.hasWork(serial), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(client.hasWork(serial), "timed out", file: file, line: line)
    }

    private func refresh() async {
        client.refresh(serial)
        await settle()
    }

    private var layout: NanoleafLayout { shapes.layout(deviceID)! }

    func testReadingsPopulateTheWallAndADamagedRefreshKeepsTheTrustedLayout() async throws {
        XCTAssertEqual(shapes.layout(deviceID)?.paintablePanels.count, 6)
        XCTAssertEqual(shapes.wall(deviceID).output, .nativeEffect(name: "Northern Lights"))
        XCTAssertEqual(shapes.displayOrientation(deviceID), 240)
        XCTAssertEqual(shapes.wall(deviceID).firmware, "9.2.0")
        let trusted = shapes.layout(deviceID)
        fake.corruptLayout = true
        await refresh()
        XCTAssertEqual(shapes.layout(deviceID), trusted)
        XCTAssertEqual(shapes.wall(deviceID).topologyProblem, .malformed("panel 77 has no readable x position"))
        fake.corruptLayout = false
        await refresh()
        XCTAssertNil(shapes.wall(deviceID).topologyProblem)
    }

    func testOrientationIsPendingUntilTheControllerReportsIt() async throws {
        fake.responseDelay = 0.05
        shapes.requestOrientation(95, for: deviceID)
        XCTAssertEqual(shapes.wall(deviceID).orientation.status, .pending(requested: 95))
        XCTAssertEqual(shapes.displayOrientation(deviceID), 95, "the draft view follows the request while it is pending")
        await settle()
        XCTAssertEqual(shapes.wall(deviceID).orientation.status, .confirmed(95))
        XCTAssertEqual(shapes.arrangement(deviceID)?.globalOrientation, 95)

        fake.failNext["panelLayout"] = 422
        shapes.requestOrientation(400, for: deviceID)
        await settle()
        XCTAssertEqual(shapes.wall(deviceID).orientation.status,
                       .failed(requested: 40, reason: NanoleafError.http(422).localizedDescription))
        XCTAssertEqual(shapes.displayOrientation(deviceID), 95, "a rejected write never shows as applied")
        shapes.dismissOrientationFailure(deviceID)
        XCTAssertEqual(shapes.wall(deviceID).orientation.status, .confirmed(95))
    }

    func testAShownDesignIsAttributedOnlyAfterTheControllerReportsIt() async throws {
        var design = NanoleafPanelDesign.uniform(.white, panelIDs: [9, 77])
        design.paint(NanoleafPanelColor(hex: "#FF8000")!, panels: [77])
        let reconciliation = shapes.show(design, on: deviceID)
        XCTAssertEqual(reconciliation?.uncovered, [1204, 5120, 31000, 64001])
        XCTAssertEqual(shapes.wall(deviceID).output, .design(confirmed: false))
        await settle()
        XCTAssertEqual(shapes.wall(deviceID).output, .design(confirmed: true))
        XCTAssertEqual(shapes.showingDesign(for: deviceID), design)
        let sent = try XCTUnwrap(fake.requests.compactMap(\.write).last { $0["animType"] as? String == "static" })
        XCTAssertEqual(sent["animData"] as? String,
                       "6 9 1 255 255 255 0 3 77 1 255 128 0 0 3 1204 1 0 0 0 0 3 5120 1 0 0 0 0 3 31000 1 0 0 0 0 3 64001 1 0 0 0 0 3")

        fake.simulateExternalSelection("Evening")
        await refresh()
        XCTAssertEqual(shapes.wall(deviceID).output, .nativeEffect(name: "Evening"))
        XCTAssertNil(shapes.showingDesign(for: deviceID), "a scene chosen elsewhere releases LumenDesk's claim")
        XCTAssertEqual(shapes.designs[deviceID], design, "the design itself is kept for re-applying")
    }

    func testAReadingTakenBeforeTheWriteLandsSaysNothingAboutIt() async throws {
        await settle()
        let stale = try XCTUnwrap(lastInfo)
        XCTAssertEqual(stale.selectedEffectName, "Northern Lights")
        fake.responseDelay = 0.05
        let design = NanoleafPanelDesign.uniform(.white, panelIDs: layout.paintableIDs)
        shapes.show(design, on: deviceID)
        shapes.didRead(deviceID: deviceID, info: stale)
        XCTAssertEqual(shapes.showingDesign(for: deviceID), design)
        XCTAssertEqual(shapes.wall(deviceID).output, .design(confirmed: false))
        await settle()
        XCTAssertEqual(shapes.wall(deviceID).output, .design(confirmed: true))
        // Readings arrive in the order the lane took them, so once the write
        // is acknowledged a contrary reading is the truth.
        shapes.didRead(deviceID: deviceID, info: stale)
        XCTAssertNil(shapes.showingDesign(for: deviceID))
    }

    func testAFailedDisplayLetsTheNextReadingDecide() async throws {
        fake.failNext["display"] = 500
        shapes.show(.uniform(.white, panelIDs: layout.paintableIDs), on: deviceID)
        await settle()
        XCTAssertEqual(shapes.wall(deviceID).output, .unknown)
        XCTAssertFalse(shapes.wall(deviceID).awaitingWrite)
        await refresh()
        XCTAssertEqual(shapes.wall(deviceID).output, .nativeEffect(name: "Northern Lights"))
        XCTAssertNil(shapes.showingDesign(for: deviceID))
    }

    func testAnotherAppTakingTheWallEndsTheStreamAndNamesItsOwner() async throws {
        shapes.beginStream(deviceID, owner: "music:all")
        await settle()
        await refresh()
        XCTAssertEqual(shapes.wall(deviceID).output, .stream(owner: "music:all"))
        shapes.beginStream(deviceID, owner: "music:all")
        XCTAssertFalse(shapes.wall(deviceID).awaitingWrite, "restarting the open stream expects no new acknowledgement")
        XCTAssertTrue(released.isEmpty)

        fake.simulateExternalSelection("Evening")
        await refresh()
        XCTAssertEqual(released, ["music:all"])
        XCTAssertNil(shapes.wall(deviceID).claim)
        XCTAssertEqual(client.streamStatus(serial), .idle)
        let sent = datagrams.sent.count
        shapes.submit([NanoleafPanelFrame(panelID: 9, rgb: .black, transition: 1)], to: deviceID, owner: "music:all")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(datagrams.sent.count, sent, "nothing is sent over the other app's choice")
    }

    func testCancellingAPreviewRestoresTheEarlierSceneWhileLumenDeskStillOwnsTheWall() async throws {
        shapes.beginSession(deviceID, origin: .uniform(.white), design: .uniform(.white, panelIDs: layout.paintableIDs))
        shapes.setPreviewing(true, for: deviceID)
        await settle()
        shapes.edit(deviceID) { $0.edit { $0.paint(.black, panels: [9]) } }
        await settle()
        await refresh()
        XCTAssertEqual(shapes.wall(deviceID).output, .preview)
        XCTAssertNil(shapes.endSession(deviceID))
        await settle()
        XCTAssertEqual(fake.select, "Northern Lights", "the scene that was showing before the preview is back")
        XCTAssertNil(shapes.session(deviceID))
    }

    func testAPreviewNeverUndoesAChoiceMadeElsewhereAfterIt() async throws {
        shapes.beginSession(deviceID, origin: .uniform(.white), design: .uniform(.white, panelIDs: layout.paintableIDs))
        shapes.setPreviewing(true, for: deviceID)
        await settle()
        fake.simulateExternalSelection("Evening")
        await refresh()
        let selects = fake.requests.filter { $0.body?["select"] != nil }.count
        XCTAssertNil(shapes.endSession(deviceID))
        await settle()
        XCTAssertEqual(fake.select, "Evening")
        XCTAssertEqual(fake.requests.filter { $0.body?["select"] != nil }.count, selects)
    }

    func testAPreviewOverAnAnimationSaysItCannotBeRestored() async throws {
        fake.simulateExternalSelection("*Dynamic*")
        await refresh()
        shapes.beginSession(deviceID, origin: .uniform(.white), design: .uniform(.white, panelIDs: layout.paintableIDs))
        shapes.setPreviewing(true, for: deviceID)
        await settle()
        let message = shapes.endSession(deviceID)
        XCTAssertNotNil(message)
        XCTAssertFalse(fake.requests.contains { $0.body?["select"] != nil })
    }

    func testStreamOwnershipIsEnforcedEndToEnd() async throws {
        shapes.beginStream(deviceID, owner: "music:all")
        let frames = layout.paintablePanels.map { NanoleafPanelFrame(panelID: $0.panelID, rgb: .black, transition: 1) }
        shapes.submit(frames, to: deviceID, owner: "music:all")
        await settle()
        XCTAssertEqual(datagrams.sent.count, 1)
        XCTAssertEqual(shapes.streams[deviceID], .streaming(owner: "music:all"))
        shapes.submit(frames, to: deviceID, owner: "effect:all")
        shapes.endStream(deviceID, owner: "effect:all")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(datagrams.sent.count, 1)
        XCTAssertEqual(shapes.streams[deviceID], .streaming(owner: "music:all"))
        shapes.endStream(deviceID, owner: "music:all")
        XCTAssertEqual(shapes.streams[deviceID], .idle)
        XCTAssertNil(shapes.wall(deviceID).claim)
    }

    func testDemoModeSimulatesWithoutSendingAnything() async throws {
        await settle()
        live = false
        let before = fake.requests.count
        shapes.requestOrientation(123, for: deviceID)
        XCTAssertEqual(shapes.wall(deviceID).orientation.status, .confirmed(123))
        shapes.show(.uniform(.white, panelIDs: layout.paintableIDs), on: deviceID)
        shapes.identifyPanel(9, on: deviceID)
        shapes.identifyWall(deviceID)
        shapes.beginStream(deviceID, owner: "music:all")
        shapes.submit([NanoleafPanelFrame(panelID: 9, rgb: .black, transition: 1)], to: deviceID, owner: "music:all")
        await shapes.loadLibrary(deviceID)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fake.requests.count, before, "Demo Mode never reaches the controller")
        XCTAssertTrue(datagrams.sent.isEmpty)
        guard case .failed = shapes.libraries[deviceID] else { return XCTFail("library must explain it needs a real controller") }
    }

    func testTapsOnTheWallAreRecordedForTheEditor() {
        shapes.handle(deviceID: deviceID, event: .touch(gesture: .singleTap, panelID: 77))
        XCTAssertEqual(shapes.wall(deviceID).touchedPanel, 77)
        shapes.handle(deviceID: deviceID, event: .touch(gesture: .swipeUp, panelID: nil))
        XCTAssertEqual(shapes.wall(deviceID).touchedPanel, 77)
    }

    func testSnapshotsCarryDesignsGroupsAndLayoutsButNotLiveClaims() async throws {
        shapes.show(.uniform(.white, panelIDs: [9]), on: deviceID)
        shapes.saveGroup(named: "Top row", panelIDs: [77, 31000], for: deviceID)
        shapes.saveDesign(.uniform(.black, panelIDs: [9]), named: " Night ", for: deviceID)
        await settle()
        let snapshot = shapes.snapshot()
        XCTAssertEqual(snapshot.groups[deviceID]?.first?.panelIDs, [77, 31000])
        XCTAssertEqual(snapshot.savedDesigns.first?.name, "Night")
        XCTAssertEqual(snapshot.arrangements[deviceID]?.layout.paintablePanels.count, 6)

        let restored = NanoleafShapesController(client: client)
        restored.restore(snapshot)
        XCTAssertEqual(restored.snapshot(), snapshot)
        XCTAssertNil(restored.showingDesign(for: deviceID), "a claim on the wall does not survive a relaunch unverified")
        XCTAssertEqual(restored.displayOrientation(deviceID), 240)

        // Demo Mode sets the workspace aside mid-write; pausing drops the
        // write, so coming back must not wait for its acknowledgement.
        shapes.show(.uniform(.black, panelIDs: [9]), on: deviceID)
        let workspace = shapes.workspaceSnapshot()
        XCTAssertTrue(workspace.walls[deviceID]?.awaitingWrite ?? false)
        await settle()
        shapes.restoreWorkspace(workspace)
        XCTAssertFalse(shapes.wall(deviceID).awaitingWrite)
        XCTAssertEqual(shapes.showingDesign(for: deviceID), .uniform(.black, panelIDs: [9]))
    }
}
