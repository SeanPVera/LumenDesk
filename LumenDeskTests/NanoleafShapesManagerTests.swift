import SwiftUI
import XCTest
@testable import LumenDesk

/// LightManager driving a Shapes wall end to end: the fake controller from
/// `NanoleafShapesClientTests` answers HTTP, a recording sender stands in
/// for UDP, and what reaches the "wall" is read back with decoders that do
/// not share code with the encoders under test.
@MainActor
final class NanoleafShapesManagerTests: XCTestCase {
    private var fake: FakeShapesController!
    private var datagrams: RecordingDatagrams!
    private var client: NanoleafClient!
    private var manager: LightManager!
    private var directory: URL!
    private let wallID = "nanoleaf:\(FakeShapesController.serial)"
    private let serial = FakeShapesController.serial
    private let panels: Set<Int> = [9, 77, 1204, 5120, 31000, 64001]

    override func setUp() async throws {
        fake = FakeShapesController()
        datagrams = RecordingDatagrams()
        FakeShapesURLProtocol.controller = fake
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        client = makeClient()
        manager = makeManager(client)
        try await manager.pairNanoleaf(host: fake.endpoint.host)
        XCTAssertNotNil(manager.shapes.layout(wallID))
    }

    override func tearDown() async throws {
        manager?.stopAllEffects(restore: false)
        let deadline = Date().addingTimeInterval(2)
        while client.hasWork(serial), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        client.pause()
        FakeShapesURLProtocol.controller = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeClient() -> NanoleafClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeShapesURLProtocol.self]
        return NanoleafClient(credentials: InMemoryShapesCredentials(), session: URLSession(configuration: configuration),
                              listensForEvents: false, datagrams: datagrams, resolver: FixedResolver(address: "192.0.2.44"))
    }

    private func makeManager(_ client: NanoleafClient) -> LightManager {
        LightManager(defaults: UserDefaults(suiteName: "LumenDeskTests.Shapes.\(UUID().uuidString)")!,
                     persistenceStore: PersistenceStore(fileURL: directory.appendingPathComponent("state.json")),
                     nanoleafClient: client)
    }

    private func wallDevice() throws -> LightDevice {
        try XCTUnwrap(manager.devices.first { $0.id == wallID })
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ predicate: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the wall", file: file, line: line)
    }

    /// The newest static layout the controller was asked to display.
    private func lastStatic() -> [Int: [Int]] {
        let write = fake.requests.compactMap(\.write).last {
            $0["command"] as? String == "display" && $0["animType"] as? String == "static"
        }
        return IndependentAnimData.decodeStatic(write?["animData"] as? String)
    }

    private func masterBrightnessWrites() -> [Int] {
        fake.requests.filter { $0.path.hasSuffix("/state") }
            .compactMap { ($0.body?["brightness"] as? [String: Any])?["value"] as? Int }
    }

    private func close(_ actual: [Int]?, _ expected: [Int], tolerance: Int = 2,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let actual, actual.count >= expected.count else { return XCTFail("missing panel colour", file: file, line: line) }
        for (a, e) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(abs(a - e), tolerance, "\(actual) vs \(expected)", file: file, line: line)
        }
    }

    // MARK: Themes

    func testAThemeLandsPanelByPanelAlongTheWallAsOriented() async throws {
        let wall = try wallDevice()
        XCTAssertEqual(manager.themeCapability(for: wall), .panels(count: 6))
        let theme = try XCTUnwrap(LightingCatalog.themes.first { $0.id == "aurora" })
        manager.applyTheme(theme, scope: .all)
        await waitUntil { self.lastStatic().count == 6 }
        let sent = lastStatic()
        XCTAssertEqual(Set(sent.keys), panels, "every light panel, and nothing else, is addressed")
        XCTAssertGreaterThan(Set(sent.values.map { Array($0.prefix(3)) }).count, 3, "the wall is not one big bulb")
        // The fake reports orientation 240°. Turned clockwise by 240°, the
        // leftmost panel is 77 (x' = x·cos240 + y·sin240 = -100.5), not 31000,
        // which is leftmost in raw layout coordinates. Aurora's first colour
        // is #38E8D4.
        close(sent[77], [0x38, 0xE8, 0xD4])
        XCTAssertNotEqual(Array(sent[31000]?.prefix(3) ?? []), Array(sent[77]?.prefix(3) ?? []))
        await waitUntil { self.masterBrightnessWrites().contains(NanoleafProtocol.percent(theme.brightness)) }
        await waitUntil { self.manager.shapes.wall(self.wallID).output == .design(confirmed: true) }
    }

    // MARK: Scenes and undo

    func testAScenePutsTheCapturedDesignBackOnTheWall() async throws {
        let wall = try wallDevice()
        var design = NanoleafPanelDesign.uniform(.white, panelIDs: panels)
        design.paint(try XCTUnwrap(NanoleafPanelColor(hex: "#FF0000")), panels: [9])
        manager.applyShapesDesign(design, to: wall)
        await waitUntil { self.manager.shapes.wall(self.wallID).output == .design(confirmed: true) }
        manager.captureScene(name: "Red corner")
        let scene = try XCTUnwrap(manager.scenes.last)
        XCTAssertEqual(scene.snapshots[wallID]?.nanoleafDesign, design)
        let decoded = try JSONDecoder().decode(LightingScene.self, from: JSONEncoder().encode(scene))
        XCTAssertEqual(decoded.snapshots[wallID]?.nanoleafDesign, design, "a saved scene keeps every panel")

        manager.selectNanoleafEffect(wall, name: "Evening")
        await waitUntil { self.fake.select == "Evening" && self.client.isIdle(self.serial) }
        XCTAssertNil(manager.shapes.showingDesign(for: wallID))
        let displays = fake.requests.count
        manager.applyScene(decoded, allowTurningOff: true, reviewed: true)
        await waitUntil { self.fake.select == "*Static*" && self.fake.requests.count > displays && self.client.isIdle(self.serial) }
        close(lastStatic()[9], [255, 0, 0])
        close(lastStatic()[77], [255, 255, 255])
        XCTAssertEqual(manager.shapes.showingDesign(for: wallID), design)
    }

    func testUndoPutsThePreviousDesignBack() async throws {
        let wall = try wallDevice()
        let red = NanoleafPanelDesign.uniform(try XCTUnwrap(NanoleafPanelColor(hex: "#FF0000")), panelIDs: panels)
        let blue = NanoleafPanelDesign.uniform(try XCTUnwrap(NanoleafPanelColor(hex: "#0000FF")), panelIDs: panels)
        manager.applyShapesDesign(red, to: wall)
        await waitUntil { self.lastStatic()[9].map { Array($0.prefix(3)) } == [255, 0, 0] }
        // Changes to one light within a second coalesce into one undo step.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        manager.applyShapesDesign(blue, to: wall)
        await waitUntil { self.lastStatic()[9].map { Array($0.prefix(3)) } == [0, 0, 255] }
        manager.undo()
        await waitUntil { self.lastStatic()[9].map { Array($0.prefix(3)) } == [255, 0, 0] }
        await waitUntil { self.manager.shapes.showingDesign(for: self.wallID) == red }
    }

    // MARK: Live output

    func testAnEffectStreamsDifferentColoursToDifferentPanelsThenRestores() async throws {
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id == "color-flow" })
        manager.startEffect(effect, scope: .all)
        await waitUntil(4) { self.datagrams.sent.count >= 2 }
        let activations = fake.requests.compactMap(\.write).filter { $0["animType"] as? String == "extControl" }
        XCTAssertEqual(activations.count, 1)
        let last = try XCTUnwrap(datagrams.sent.last)
        XCTAssertEqual(last.host, "192.0.2.44")
        XCTAssertEqual(last.port, 60222)
        let frame = IndependentStreamDecoder.decode(last.data)
        XCTAssertEqual(Set(frame.keys), panels)
        XCTAssertGreaterThan(Set(frame.values.map { Array($0.prefix(3)) }).count, 2, "each panel takes its own place in the flow")
        // Levels ride in each panel's colour, so master brightness opens to full.
        await waitUntil { self.masterBrightnessWrites().contains(100) }
        XCTAssertNotNil(manager.animatingEffect(for: wallID))

        manager.stopEffect(scope: .all, restore: true)
        await waitUntil { self.fake.select == "Northern Lights" && self.client.isIdle(self.serial) }
        XCTAssertEqual(client.streamStatus(serial), .idle)
        let sent = datagrams.sent.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(datagrams.sent.count, sent, "a stopped show sends nothing more")
    }

    func testAnotherAppTakingTheWallReleasesItFromTheShow() async throws {
        let wall = try wallDevice()
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id == "color-flow" })
        manager.startEffect(effect, scope: .all)
        await waitUntil(4) { self.datagrams.sent.count >= 1 }
        fake.simulateExternalSelection("Evening")
        manager.refreshShapes(wall)
        await waitUntil { self.manager.animatingEffect(for: self.wallID) == nil }
        XCTAssertEqual(client.streamStatus(serial), .idle)
        let sent = datagrams.sent.count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(datagrams.sent.count, sent, "nothing streams over the other app's choice")
        manager.stopEffect(scope: .all, restore: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        await waitUntil { self.client.isIdle(self.serial) }
        XCTAssertEqual(fake.select, "Evening", "stopping the show does not undo the other app's choice")
    }

    func testMusicModePlacesEachPanelWhereItSitsOnTheWall() throws {
        let descriptor = try XCTUnwrap(manager.musicFixtureDescriptors(in: .all).first { $0.id == wallID })
        XCTAssertEqual(descriptor.transport, .nanoleafStream)
        XCTAssertEqual(descriptor.segmentCount, 6)
        XCTAssertEqual(descriptor.resolvedRole, .motion)
        let positions = try XCTUnwrap(descriptor.segmentPositions)
        // Segment i is the i-th panel by ID.
        let ids = [9, 77, 1204, 5120, 31000, 64001]
        let raw: [Int: (Double, Double)] = [9: (-67, -38.68), 77: (100.5, 58.02), 1204: (67, -38.68),
                                           5120: (0, 0), 31000: (-100.5, 58.02), 64001: (0, -96.7)]
        // Left to right after turning clockwise by the reported 240°.
        let theta = 240.0 * .pi / 180
        func across(_ id: Int) -> Double { raw[id]!.0 * cos(theta) + raw[id]!.1 * sin(theta) }
        for (i, a) in ids.enumerated() {
            for (j, b) in ids.enumerated() where i < j {
                let difference = across(a) - across(b)
                if abs(difference) < 1e-6 {
                    XCTAssertEqual(positions[i], positions[j], accuracy: 1e-9, "\(a) and \(b) share a column")
                } else {
                    XCTAssertEqual(positions[i] < positions[j], difference < 0, "\(a) vs \(b)")
                }
            }
        }
        XCTAssertEqual(MusicLightingRenderer.minimumInterval(for: .nanoleafStream), 0.1)
    }

    // MARK: Orientation

    func testOrientationWritesReadsBackAndReaimsSpatialOutput() async throws {
        let wall = try wallDevice()
        let before = try XCTUnwrap(manager.musicFixtureDescriptors(in: .all).first?.segmentPositions)
        manager.requestShapesOrientation(95, for: wall)
        await waitUntil { self.manager.shapes.wall(self.wallID).orientation.status == .confirmed(95) }
        XCTAssertEqual(fake.orientation, 95)
        let write = try XCTUnwrap(fake.requests.last { $0.path.hasSuffix("/panelLayout") })
        XCTAssertEqual(write.body as NSDictionary?, ["globalOrientation": ["value": 95]] as NSDictionary)
        let after = try XCTUnwrap(manager.musicFixtureDescriptors(in: .all).first?.segmentPositions)
        XCTAssertNotEqual(before, after, "the same panels, re-aimed for the new orientation")
    }

    // MARK: Demo Mode

    func testDemoModeNeverReachesTheRealWallAndGivesItBack() async throws {
        let wall = try wallDevice()
        let design = NanoleafPanelDesign.uniform(try XCTUnwrap(NanoleafPanelColor(hex: "#00FF80")), panelIDs: panels)
        manager.applyShapesDesign(design, to: wall)
        await waitUntil { self.manager.shapes.wall(self.wallID).output == .design(confirmed: true) && self.client.isIdle(self.serial) }
        let requests = fake.requests.count

        manager.enterDemoMode()
        let demoWall = try XCTUnwrap(manager.devices.first { $0.brand == .nanoleaf })
        XCTAssertEqual(demoWall.id, "demo:6")
        XCTAssertEqual(manager.shapes.wall(demoWall.id).output, .design(confirmed: true))
        XCTAssertNil(manager.shapes.layout(wallID), "the real wall is set aside, not shown in the demo")
        let demoPanels = try XCTUnwrap(manager.shapes.layout(demoWall.id)).paintableIDs
        manager.applyShapesDesign(.uniform(.white, panelIDs: demoPanels), to: demoWall)
        manager.requestShapesOrientation(90, for: demoWall)
        let lounge = try XCTUnwrap(manager.rooms.first { $0.lightIDs.contains(demoWall.id) })
        let effect = try XCTUnwrap(LightingCatalog.effects.first { $0.id == "color-flow" })
        manager.startEffect(effect, scope: .room(lounge.id))
        try await Task.sleep(nanoseconds: 600_000_000)
        guard case .stream = manager.shapes.wall(demoWall.id).output else {
            return XCTFail("the simulated wall should show the show panel by panel")
        }
        manager.stopAllEffects(restore: true)
        XCTAssertEqual(fake.requests.count, requests, "Demo Mode never reaches the controller")
        XCTAssertTrue(datagrams.sent.isEmpty, "or its UDP port")

        manager.exitDemoMode()
        XCTAssertEqual(manager.shapes.showingDesign(for: wallID), design, "the real wall's design comes back")
        XCTAssertNil(manager.shapes.layout("demo:6"))
    }

    // MARK: Persistence

    func testShapesStateSurvivesRelaunchAndExportsWithoutTheCredential() async throws {
        let wall = try wallDevice()
        let design = NanoleafPanelDesign.uniform(try XCTUnwrap(NanoleafPanelColor(hex: "#FF8000")), panelIDs: panels)
        manager.applyShapesDesign(design, to: wall)
        manager.shapes.saveGroup(named: "Top row", panelIDs: [77, 31000], for: wallID)
        manager.shapes.saveDesign(design, named: "Amber", for: wallID)
        manager.requestShapesOrientation(30, for: wall)
        await waitUntil {
            self.manager.shapes.wall(self.wallID).orientation.status == .confirmed(30)
                && self.manager.shapes.designs[self.wallID] == design && self.client.isIdle(self.serial)
        }

        let data = try XCTUnwrap(manager.exportConfigurationData())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(FakeShapesController.token), "the pairing token never leaves the Keychain")
        XCTAssertTrue(text.contains("nanoleafArrangements"))

        let relaunched = makeManager(makeClient())
        XCTAssertEqual(relaunched.shapes.layout(wallID), manager.shapes.layout(wallID))
        XCTAssertEqual(relaunched.shapes.displayOrientation(wallID), 30)
        XCTAssertEqual(relaunched.shapes.designs[wallID], design)
        XCTAssertEqual(relaunched.shapes.groups[wallID]?.first?.panelIDs, [77, 31000])
        XCTAssertEqual(relaunched.shapes.savedDesigns(for: wallID).first?.name, "Amber")
        XCTAssertNil(relaunched.shapes.showingDesign(for: wallID), "what the wall shows is re-read, not assumed")

        // An export from before Shapes support imports without dropping it.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["nanoleafDesigns", "nanoleafSavedDesigns", "nanoleafPanelGroups", "nanoleafArrangements"] {
            XCTAssertNotNil(object.removeValue(forKey: key), key)
        }
        XCTAssertTrue(relaunched.importRoomsData(try JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(relaunched.shapes.designs[wallID], design)
        XCTAssertEqual(relaunched.shapes.groups[wallID]?.first?.name, "Top row")
    }
}

/// Reads a one-frame static `animData` string without the encoder under
/// test: `[panel: [R, G, B, W, transition]]`, or empty if malformed.
enum IndependentAnimData {
    static func decodeStatic(_ text: String?) -> [Int: [Int]] {
        guard let text else { return [:] }
        let numbers = text.split(separator: " ").compactMap { Int($0) }
        guard let count = numbers.first else { return [:] }
        var result: [Int: [Int]] = [:]
        var index = 1
        for _ in 0..<count {
            guard index + 7 <= numbers.count, numbers[index + 1] == 1 else { return [:] }
            result[numbers[index]] = Array(numbers[(index + 2)...(index + 6)])
            index += 7
        }
        return index == numbers.count ? result : [:]
    }
}
