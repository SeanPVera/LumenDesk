import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LumenDesk

/// Drives the real `NanoleafClient` against a fake Shapes controller that
/// follows the documented OpenAPI routes, and against a recording datagram
/// sender. Nothing here reaches the network or a physical controller.
@MainActor
final class NanoleafShapesClientTests: XCTestCase {
    private var controller: FakeShapesController!
    private var datagrams: RecordingDatagrams!
    private var client: NanoleafClient!
    private var updates: [NanoleafInfo] = []
    private var failures: [(NanoleafOperation, NanoleafError)] = []
    private var statuses: [NanoleafStreamStatus] = []

    override func setUp() async throws {
        controller = FakeShapesController()
        datagrams = RecordingDatagrams()
        FakeShapesURLProtocol.controller = controller
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeShapesURLProtocol.self]
        client = NanoleafClient(credentials: InMemoryShapesCredentials(),
                                session: URLSession(configuration: configuration),
                                listensForEvents: false,
                                datagrams: datagrams,
                                resolver: FixedResolver(address: "192.0.2.44"))
        updates = []
        failures = []
        statuses = []
        client.onUpdate = { [weak self] _, info in self?.updates.append(info) }
        client.onOperationFailure = { [weak self] _, operation, error in self?.failures.append((operation, error)) }
        client.onStreamStatus = { [weak self] _, status in self?.statuses.append(status) }
        try await client.pair(endpoint: controller.endpoint)
    }

    override func tearDown() async throws {
        // Let the last readback finish first. Cancelling a request at the
        // instant it completes deadlocks swift-corelibs-foundation's
        // URLSession (Linux), and tearing down mid-request tests nothing.
        let deadline = Date().addingTimeInterval(1)
        while client.hasWork(serial), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        client.pause()
        client = nil
        FakeShapesURLProtocol.controller = nil
    }

    private let serial = FakeShapesController.serial

    private func waitUntil(_ timeout: TimeInterval = 2, _ predicate: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    // MARK: Topology

    func testEveryRefreshCarriesTheTopologyAndAMalformedOneKeepsStateUsable() async throws {
        let first = try XCTUnwrap(updates.last)
        guard case .success(let arrangement) = first.topology else { return XCTFail("expected a layout") }
        XCTAssertEqual(arrangement.globalOrientation, 240)
        XCTAssertEqual(arrangement.layout.paintablePanels.map(\.panelID), [9, 77, 1204, 5120, 31000, 64001])
        XCTAssertEqual(first.firmwareVersion, "9.2.0")

        controller.corruptLayout = true
        let count = updates.count
        client.refresh(serial)
        await waitUntil { self.updates.count > count }
        let damaged = try XCTUnwrap(updates.last)
        XCTAssertEqual(damaged.topology, .failure(.malformed("panel 77 has no readable x position")))
        XCTAssertEqual(damaged.state.brightness.value, 80, "a bad layout never costs the controller's state")
    }

    // MARK: Orientation

    func testOrientationUsesTheDocumentedWriteAndIsConfirmedOnlyByReadback() async throws {
        let count = updates.count
        client.setOrientation(serial, degrees: 95)
        await waitUntil { self.updates.count > count }
        let write = try XCTUnwrap(controller.requests.first { $0.path.hasSuffix("/panelLayout") })
        XCTAssertEqual(write.method, "PUT")
        XCTAssertEqual(write.body as NSDictionary?, ["globalOrientation": ["value": 95]] as NSDictionary)
        let after = controller.requests.firstIndex { $0.path.hasSuffix("/panelLayout") }!
        XCTAssertEqual(controller.requests[after + 1].method, "GET", "the 204 is not trusted; the value is read back")
        guard case .success(let arrangement) = try XCTUnwrap(updates.last).topology else { return XCTFail() }
        XCTAssertEqual(arrangement.globalOrientation, 95)
    }

    func testARejectedOrientationIsReportedAndNothingReadsBackAsApplied() async throws {
        controller.failNext["panelLayout"] = 422
        client.setOrientation(serial, degrees: 10)
        await waitUntil { !self.failures.isEmpty }
        XCTAssertEqual(failures.first?.0, .orientation)
        XCTAssertEqual(failures.first?.1, .http(422))
        XCTAssertEqual(controller.orientation, 240)
    }

    func testRapidOrientationChangesCoalesceToTheLatest() async throws {
        controller.responseDelay = 0.05
        for degrees in [10, 20, 30, 40, 50] { client.setOrientation(serial, degrees: degrees) }
        await waitUntil { self.controller.orientation == 50 && self.client.isIdle(self.serial) }
        let writes = controller.requests.filter { $0.path.hasSuffix("/panelLayout") }
        XCTAssertLessThanOrEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.body as NSDictionary?, ["globalOrientation": ["value": 50]] as NSDictionary)
    }

    // MARK: Panel output

    func testPanelDisplaySendsStaticAnimDataAndOnlyTheNewestQueuedLayout() async throws {
        controller.responseDelay = 0.05
        func frames(_ value: UInt8) -> [NanoleafPanelFrame] {
            [NanoleafPanelFrame(panelID: 9, rgb: NanoleafRGB(red: value, green: 0, blue: 0), transition: 1),
             NanoleafPanelFrame(panelID: 77, rgb: NanoleafRGB(red: 0, green: value, blue: 0), transition: 1)]
        }
        for value in stride(from: UInt8(10), through: 200, by: 10) { client.displayPanels(serial, frames: frames(value)) }
        await waitUntil { self.controller.select == "*Static*" && self.client.isIdle(self.serial) }
        let displays = controller.requests.compactMap { $0.write }.filter { $0["command"] as? String == "display" }
        XCTAssertLessThanOrEqual(displays.count, 2, "twenty paint strokes must not queue twenty requests")
        XCTAssertEqual(displays.last?["animType"] as? String, "static")
        XCTAssertEqual(displays.last?["animData"] as? String, "2 9 1 200 0 0 0 1 77 1 0 200 0 0 1")
    }

    func testAnEffectChosenAfterPaintingReplacesTheQueuedPaint() async throws {
        controller.responseDelay = 0.05
        client.refresh(serial) // occupy the lane so both writes queue behind it
        client.displayPanels(serial, frames: [NanoleafPanelFrame(panelID: 9, rgb: .black, transition: 1)])
        client.selectEffect(serial, name: "Northern Lights")
        await waitUntil { self.client.isIdle(self.serial) }
        XCTAssertFalse(controller.requests.contains { $0.write?["animType"] as? String == "static" })
        XCTAssertEqual(controller.select, "Northern Lights")
    }

    func testPanelIdentificationIsATemporaryDisplay() async throws {
        let layout = try XCTUnwrap(try? updates.last?.topology.get().layout)
        client.identifyPanel(serial, panelID: 1204, layout: layout)
        client.identifyPanel(serial, panelID: 0, layout: layout) // the controller entry is never a target
        await waitUntil { self.controller.requests.contains { $0.write?["command"] as? String == "displayTemp" } }
        await waitUntil { self.client.isIdle(self.serial) }
        let temporary = controller.requests.compactMap(\.write).filter { $0["command"] as? String == "displayTemp" }
        XCTAssertEqual(temporary.count, 1)
        XCTAssertEqual(temporary.first?["duration"] as? Int, 4)
        XCTAssertEqual(controller.select, "Northern Lights", "the controller's own selection is not replaced")
    }

    // MARK: Stored designs and effects

    func testSavingADesignRefusesAnExistingNameUnlessConfirmedAndVerifiesStorage() async throws {
        let frames = [NanoleafPanelFrame(panelID: 9, rgb: NanoleafRGB(red: 1, green: 2, blue: 3), transition: 1)]
        do {
            try await client.saveStaticDesign(serial, name: " evening ", frames: frames, allowOverwrite: false)
            XCTFail("expected a name conflict")
        } catch {
            XCTAssertEqual(error as? NanoleafError, .nameConflict)
        }
        XCTAssertFalse(controller.requests.contains { $0.write?["command"] as? String == "add" }, "nothing was overwritten")
        XCTAssertTrue(failures.isEmpty, "an awaited request reports to its caller, not the global callback")

        let verified = try await client.saveStaticDesign(serial, name: "Reading", frames: frames, allowOverwrite: false)
        XCTAssertTrue(verified)
        XCTAssertTrue(controller.effectsList.contains("Reading"))
        let add = try XCTUnwrap(controller.requests.compactMap(\.write).first { $0["command"] as? String == "add" })
        XCTAssertEqual(add["animName"] as? String, "Reading")
        XCTAssertEqual(add["animData"] as? String, "1 9 1 1 2 3 0 1")

        controller.corruptStoredAnimData = true
        let mismatch = try await client.saveStaticDesign(serial, name: "Evening", frames: frames, allowOverwrite: true)
        XCTAssertFalse(mismatch, "a stored design that reads back differently is not reported as verified")
    }

    func testReservedAndEmptyNamesAreRefusedBeforeAnyRequest() async throws {
        let before = controller.requests.count
        for name in ["", "   ", "*Static*", String(repeating: "x", count: 65)] {
            do {
                try await client.saveStaticDesign(serial, name: name, frames: [], allowOverwrite: true)
                XCTFail("\(name) should be refused")
            } catch {
                XCTAssertEqual(error as? NanoleafError, .invalidName)
            }
        }
        XCTAssertEqual(controller.requests.count, before)
    }

    func testEffectLibraryPreviewAndSaveUseTheWriteCommands() async throws {
        let library = try await client.effectLibrary(serial)
        XCTAssertEqual(library.map(\.name), ["Northern Lights", "Evening"])
        var edited = try XCTUnwrap(library.first)
        edited.options = [NanoleafEffectOption(name: "transTime", value: .int(40))]
        try await client.previewEffect(serial, edited)
        let preview = try XCTUnwrap(controller.requests.compactMap(\.write).last)
        XCTAssertEqual(preview["command"] as? String, "display")
        XCTAssertNil(preview["animName"])
        do {
            try await client.saveEffect(serial, edited, name: "Northern Lights", allowOverwrite: false)
            XCTFail("expected a name conflict")
        } catch {
            XCTAssertEqual(error as? NanoleafError, .nameConflict)
        }
        try await client.saveEffect(serial, edited, name: "Northern Lights (slow)", allowOverwrite: false)
        XCTAssertTrue(controller.effectsList.contains("Northern Lights (slow)"))
        XCTAssertEqual(controller.effectsList.filter { $0 == "Northern Lights" }.count, 1)
        let plugins = try await client.plugins(serial)
        XCTAssertEqual(plugins.first?.name, "Flow")
    }

    // MARK: External control stream

    private func frame(_ panel: Int, _ value: UInt8) -> NanoleafPanelFrame {
        NanoleafPanelFrame(panelID: panel, rgb: NanoleafRGB(red: value, green: value, blue: value), transition: 1)
    }

    func testStreamingActivatesOnceAndPacesCoalescedFramesToTenPerSecond() async throws {
        client.startStream(serial, owner: "music")
        client.startStream(serial, owner: "music")
        for value in 1...20 {
            client.submitStreamFrame(serial, owner: "music", frames: [frame(9, UInt8(value)), frame(77, UInt8(value))])
        }
        await waitUntil { self.datagrams.sent.count >= 1 }
        let activations = controller.requests.compactMap(\.write).filter { $0["animType"] as? String == "extControl" }
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations.first?["extControlVersion"] as? String, "v2")
        XCTAssertEqual(client.streamStatus(serial), .streaming(owner: "music"))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(datagrams.sent.count, 1, "everything submitted before activation leaves as one datagram")
        let first = try XCTUnwrap(datagrams.sent.first)
        XCTAssertEqual(first.host, "192.0.2.44")
        XCTAssertEqual(first.port, 60222)
        XCTAssertEqual(IndependentStreamDecoder.decode(first.data), [9: [20, 20, 20, 0, 1], 77: [20, 20, 20, 0, 1]])

        let start = Date()
        for value in 21...60 {
            client.submitStreamFrame(serial, owner: "music", frames: [frame(9, UInt8(value))])
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThanOrEqual(Double(datagrams.sent.count - 1), elapsed / 0.1 + 1, "never faster than 10 Hz")
        XCTAssertEqual(IndependentStreamDecoder.decode(try XCTUnwrap(datagrams.sent.last).data)[9]?.first, 60,
                       "the newest frame is the one that goes out")
        let metrics = try XCTUnwrap(client.streamMetrics(serial))
        XCTAssertEqual(metrics.framesSubmitted, 60)
        XCTAssertEqual(metrics.datagramsSent, datagrams.sent.count)
    }

    func testANewerOwnerOrAnHTTPOutputEndsTheOldStream() async throws {
        client.startStream(serial, owner: "effect:room")
        await waitUntil { self.client.streamStatus(self.serial) == .streaming(owner: "effect:room") }
        client.startStream(serial, owner: "music:room")
        await waitUntil { self.client.streamStatus(self.serial) == .streaming(owner: "music:room") }
        let before = datagrams.sent.count
        client.submitStreamFrame(serial, owner: "effect:room", frames: [frame(9, 1)])
        client.stopStream(serial, owner: "effect:room")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(datagrams.sent.count, before, "a replaced owner can neither send nor stop the new stream")
        XCTAssertEqual(client.streamStatus(serial), .streaming(owner: "music:room"))

        client.selectEffect(serial, name: "Northern Lights")
        XCTAssertEqual(client.streamStatus(serial), .idle, "a chosen effect ends the stream before it is sent")
        client.submitStreamFrame(serial, owner: "music:room", frames: [frame(9, 2)])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(datagrams.sent.count, before)
    }

    func testAFailedActivationNeverSendsItsQueuedFrames() async throws {
        controller.failNext["extControl"] = 400
        client.startStream(serial, owner: "music")
        client.submitStreamFrame(serial, owner: "music", frames: [frame(9, 1)])
        await waitUntil { if case .failed = self.client.streamStatus(self.serial) { return true }; return false }
        XCTAssertEqual(client.streamStatus(serial), .failed(owner: "music", .http(400)))
        client.submitStreamFrame(serial, owner: "music", frames: [frame(9, 2)])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(datagrams.sent.isEmpty)
        XCTAssertEqual(failures.last?.0, .streamActivation)
    }

    func testStreamingWithoutAnIPv4AddressFailsHonestly() async throws {
        FakeShapesURLProtocol.controller = controller
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeShapesURLProtocol.self]
        let isolated = NanoleafClient(credentials: InMemoryShapesCredentials(), session: URLSession(configuration: configuration),
                                      listensForEvents: false, datagrams: datagrams, resolver: FixedResolver(address: nil))
        defer { isolated.pause() }
        try await isolated.pair(endpoint: controller.endpoint)
        isolated.startStream(serial, owner: "music")
        await waitUntil { if case .failed = isolated.streamStatus(self.serial) { return true }; return false }
        XCTAssertEqual(isolated.streamStatus(serial), .failed(owner: "music", .streamUnavailable))
        XCTAssertFalse(controller.requests.contains { $0.write?["animType"] as? String == "extControl" },
                       "the controller is not switched into a mode nothing can feed")
    }

    func testPausingAbandonsAwaitedRequestsAndEndsStreams() async throws {
        client.startStream(serial, owner: "music")
        await waitUntil { self.client.streamStatus(self.serial) == .streaming(owner: "music") }
        controller.responseDelay = 0.3
        let library = Task { @MainActor in try await self.client.effectLibrary(self.serial) }
        try await Task.sleep(nanoseconds: 20_000_000)
        client.pause()
        do {
            _ = try await library.value
            XCTFail("a paused client must not complete the request")
        } catch {
            XCTAssertEqual(error as? NanoleafError, .unavailable)
        }
        XCTAssertEqual(client.streamStatus(serial), .idle)
        let sent = datagrams.sent.count
        client.submitStreamFrame(serial, owner: "music", frames: [frame(9, 3)])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(datagrams.sent.count, sent)
    }

    func testTheCredentialNeverAppearsInAnythingUserFacing() async throws {
        controller.failNext["panelLayout"] = 401
        client.setOrientation(serial, degrees: 5)
        await waitUntil { !self.failures.isEmpty }
        for (_, error) in failures {
            XCTAssertFalse(error.localizedDescription.contains(FakeShapesController.token))
        }
        XCTAssertFalse(String(describing: client.streamStatus(serial)).contains(FakeShapesController.token))
        for error: NanoleafError in [.nameConflict, .invalidName, .streamUnavailable, .http(500), .pairingRequired] {
            XCTAssertFalse(error.localizedDescription.contains(FakeShapesController.token))
        }
    }

    #if canImport(Darwin)
    /// The production sender over real UDP on loopback, read back by a
    /// socket with an independent decoder.
    func testTheUDPSenderPutsTheDocumentedPacketOnTheWire() async throws {
        let queue = DispatchQueue(label: "test.nanoleaf.receiver")
        let receiver = try UDPSocket(queue: queue)
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(receiver.fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let received = LockedBox<Data?>(nil)
        receiver.onReceive = { data, _, _ in received.value = data }
        let frames = [NanoleafPanelFrame(panelID: 374, rgb: NanoleafRGB(red: 255, green: 0, blue: 255), transition: 12)]
        try NanoleafUDPSender().send(NanoleafStreamPacket.encode(frames), to: "127.0.0.1", port: port)
        await waitUntil { received.value != nil }
        XCTAssertEqual(IndependentStreamDecoder.decode(try XCTUnwrap(received.value)), [374: [255, 0, 255, 0, 12]])
    }
    #endif
}

extension NanoleafClient {
    /// Test hook: nothing queued and nothing in flight for this controller.
    func isIdle(_ serial: String) -> Bool { !hasWork(serial) }
}

// MARK: - Test doubles

final class LockedBox<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class RecordingDatagrams: NanoleafDatagramSending {
    struct Sent { let data: Data; let host: String; let port: UInt16 }
    private(set) var sent: [Sent] = []
    func send(_ data: Data, to host: String, port: UInt16) throws {
        sent.append(Sent(data: data, host: host, port: port))
    }
}

struct FixedResolver: NanoleafHostResolving {
    let address: String?
    func ipv4Address(for host: String) async -> String? { address }
}

final class InMemoryShapesCredentials: NanoleafCredentialStoring {
    var pairings: [NanoleafPairing] = []
    func load() throws -> [NanoleafPairing] { pairings }
    func save(_ pairings: [NanoleafPairing]) throws { self.pairings = pairings }
}

/// Reads a v2 external-control datagram without using the encoder under
/// test: `[panel: [R, G, B, W, transition]]`.
enum IndependentStreamDecoder {
    static func decode(_ data: Data) -> [Int: [Int]] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return [:] }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        var result: [Int: [Int]] = [:]
        var index = 2
        for _ in 0..<count {
            guard index + 8 <= bytes.count else { return [:] }
            let panel = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            let transition = Int(bytes[index + 6]) << 8 | Int(bytes[index + 7])
            result[panel] = [Int(bytes[index + 2]), Int(bytes[index + 3]), Int(bytes[index + 4]), Int(bytes[index + 5]), transition]
            index += 8
        }
        return index == bytes.count ? result : [:]
    }
}

/// A Shapes controller that follows the documented routes closely enough to
/// exercise the client: state, layout, orientation, effects and the write
/// commands, with injectable delays and failures.
final class FakeShapesController {
    static let serial = "SHAPES123"
    static let token = "fakeShapesToken42"

    struct Recorded {
        let method: String
        let path: String
        let body: [String: Any]?
        var write: [String: Any]? { body?["write"] as? [String: Any] }
    }

    let endpoint = try! NanoleafEndpoint(host: "shapes.local")
    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private var _orientation = 240
    private var _select = "Northern Lights"
    private var _effects = ["Northern Lights", "Evening"]
    private var _stored: [String: [String: Any]] = [:]
    private var _failNext: [String: Int] = [:]
    private var _delay: TimeInterval = 0
    private var _corruptLayout = false
    private var _corruptStored = false

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var requests: [Recorded] { locked { _requests } }
    var orientation: Int { locked { _orientation } }
    var select: String { locked { _select } }
    var effectsList: [String] { locked { _effects } }
    var failNext: [String: Int] {
        get { locked { _failNext } }
        set { locked { _failNext = newValue } }
    }
    var responseDelay: TimeInterval {
        get { locked { _delay } }
        set { locked { _delay = newValue } }
    }
    var corruptLayout: Bool {
        get { locked { _corruptLayout } }
        set { locked { _corruptLayout = newValue } }
    }
    var corruptStoredAnimData: Bool {
        get { locked { _corruptStored } }
        set { locked { _corruptStored = newValue } }
    }

    /// Someone chose a scene in the Nanoleaf app.
    func simulateExternalSelection(_ name: String) {
        locked { _select = name }
    }

    init() {
        _stored["Northern Lights"] = [
            "animName": "Northern Lights", "animType": "plugin", "pluginType": "color", "version": "2.0",
            "pluginUuid": "027842e4-e1d6-4a4c-a731-be74a1ebd4cf",
            "pluginOptions": [["name": "transTime", "value": 24]],
            "palette": [["hue": 120, "saturation": 100, "brightness": 100]]
        ]
        _stored["Evening"] = ["animName": "Evening", "animType": "static", "version": "2.0", "animData": "1 9 1 255 120 0 0 1"]
    }

    private func infoJSON() -> Data {
        let x: Any = _corruptLayout ? ("wide" as Any) : (100.5 as Any)
        let positions: [[String: Any]] = [
            ["panelId": 5120, "x": 0, "y": 0, "o": 0, "shapeType": 7],
            ["panelId": 77, "x": x, "y": 58.02, "o": 0, "shapeType": 7],
            ["panelId": 31000, "x": -100.5, "y": 58.02, "o": 120, "shapeType": 7],
            ["panelId": 1204, "x": 67, "y": -38.68, "o": 0, "shapeType": 9],
            ["panelId": 9, "x": -67, "y": -38.68, "o": 0, "shapeType": 9],
            ["panelId": 64001, "x": 0, "y": -96.7, "o": 60, "shapeType": 8],
            ["panelId": 0, "x": -45, "y": 105, "o": 0, "shapeType": 12]
        ]
        let object: [String: Any] = [
            "name": "Studio Shapes", "serialNo": Self.serial, "model": "NL42", "firmwareVersion": "9.2.0",
            "state": ["on": ["value": true], "brightness": ["value": 80, "max": 100, "min": 0],
                      "hue": ["value": 20, "max": 360, "min": 0], "sat": ["value": 80, "max": 100, "min": 0],
                      "ct": ["value": 3500, "max": 6500, "min": 1200], "colorMode": "effect"],
            "effects": ["select": _select, "effectsList": _effects],
            "panelLayout": ["globalOrientation": ["value": _orientation, "max": 360, "min": 0],
                            "layout": ["numPanels": positions.count, "sideLength": 0, "positionData": positions]]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// Returns status, body and how long to wait before answering.
    func respond(method: String, path: String, body: Data?) -> (Int, Data, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        _requests.append(Recorded(method: method, path: path, body: json))
        let delay = _delay
        let prefix = "/api/v1/\(Self.token)"
        func fail(_ key: String) -> Int? { _failNext.removeValue(forKey: key) }
        if method == "POST", path == "/api/v1/new" {
            return (200, Data(#"{"auth_token":"\#(Self.token)"}"#.utf8), delay)
        }
        guard path.hasPrefix(prefix) else { return (401, Data(), delay) }
        let route = String(path.dropFirst(prefix.count))
        switch (method, route) {
        case ("GET", ""):
            return (200, infoJSON(), delay)
        case ("PUT", "/state"):
            return (fail("state") ?? 204, Data(), delay)
        case ("PUT", "/identify"):
            return (204, Data(), delay)
        case ("PUT", "/panelLayout"):
            if let code = fail("panelLayout") { return (code, Data(), delay) }
            guard let value = (json?["globalOrientation"] as? [String: Any])?["value"] as? Int else { return (400, Data(), delay) }
            _orientation = value
            return (204, Data(), delay)
        case ("PUT", "/effects"):
            if let name = json?["select"] as? String {
                guard _effects.contains(name) else { return (404, Data(), delay) }
                _select = name
                return (204, Data(), delay)
            }
            guard let write = json?["write"] as? [String: Any], let command = write["command"] as? String else {
                return (400, Data(), delay)
            }
            switch command {
            case "display":
                if write["animType"] as? String == "extControl" {
                    if let code = fail("extControl") { return (code, Data(), delay) }
                    _select = "*ExtControl*"
                } else {
                    if let code = fail("display") { return (code, Data(), delay) }
                    _select = write["animType"] as? String == "static" ? "*Static*" : "*Dynamic*"
                }
                return (204, Data(), delay)
            case "displayTemp":
                return (204, Data(), delay)
            case "add":
                guard let name = write["animName"] as? String else { return (400, Data(), delay) }
                var stored = write
                stored.removeValue(forKey: "command")
                if _corruptStored, stored["animData"] != nil { stored["animData"] = "1 9 1 9 9 9 0 1" }
                _stored[name] = stored
                if !_effects.contains(name) { _effects.append(name) }
                return (204, Data(), delay)
            case "request":
                guard let name = write["animName"] as? String, let stored = _stored[name] else { return (404, Data(), delay) }
                return (200, try! JSONSerialization.data(withJSONObject: stored), delay)
            case "requestAll":
                let animations = _effects.compactMap { _stored[$0] }
                return (200, try! JSONSerialization.data(withJSONObject: ["animations": animations]), delay)
            case "requestPlugins":
                let plugins = #"{"plugins":[{"uuid":"027842e4-e1d6-4a4c-a731-be74a1ebd4cf","name":"Flow","description":"","type":"color","pluginConfig":[{"name":"transTime","type":"int","defaultValue":24,"minValue":1,"maxValue":600}]}]}"#
                return (200, Data(plugins.utf8), delay)
            default:
                return (400, Data(), delay)
            }
        default:
            return (404, Data(), delay)
        }
    }
}

final class FakeShapesURLProtocol: URLProtocol {
    static var controller: FakeShapesController?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let controller = Self.controller, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            body = data
        }
        let (status, data, delay) = controller.respond(method: request.httpMethod ?? "GET", path: url.path, body: body)
        let respond = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
