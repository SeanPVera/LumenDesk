import SwiftUI
import XCTest
@testable import LumenDesk

final class NanoleafTests: XCTestCase {
    func testAddressesAndAdvertisedPorts() throws {
        let endpoint = try NanoleafEndpoint(host: " shapes.local. ", port: 17000)
        XCTAssertEqual(try endpoint.url(path: "/api/v1/new").absoluteString, "http://shapes.local.:17000/api/v1/new")
        XCTAssertEqual(try NanoleafEndpoint(host: "192.168.1.42").port, 16021)
        XCTAssertNotNil(try NanoleafEndpoint(host: "fd00::42").url(path: "/api/v1/new"))
        for host in ["", "http://192.168.1.42", "host/path", "user@host", "host?token=1", "host:1234", "two hosts"] {
            XCTAssertThrowsError(try NanoleafEndpoint(host: host), host)
        }
        XCTAssertThrowsError(try NanoleafEndpoint(host: "host", port: 0))
        XCTAssertThrowsError(try NanoleafEndpoint(host: "host", port: 65536))
    }

    func testCommandUnitsAndBounds() throws {
        let color = NanoleafProtocol.color(hue: 0.5, saturation: 0.75, brightness: 0.23)
        XCTAssertEqual(color["hue"] as? [String: Int], ["value": 180])
        XCTAssertEqual(color["sat"] as? [String: Int], ["value": 75])
        XCTAssertEqual(color["brightness"] as? [String: Int], ["value": 23])
        XCTAssertEqual(NanoleafProtocol.color(hue: 1, saturation: 1)["hue"] as? [String: Int], ["value": 0])
        XCTAssertNil(NanoleafProtocol.color(hue: 0, saturation: 1)["brightness"])
        XCTAssertEqual(NanoleafProtocol.percent(.nan), 0)
        XCTAssertEqual(NanoleafProtocol.percent(-1), 0)
        XCTAssertEqual(NanoleafProtocol.percent(5), 100)
        XCTAssertEqual(NanoleafProtocol.kelvin(9000), 6500)
        XCTAssertEqual(NanoleafProtocol.kelvin(500), 1200)
    }

    func testShapesIdentificationAndReservedEffects() throws {
        let fixture = NanoleafFixture()
        XCTAssertTrue(try fixture.info().isShapes)
        XCTAssertEqual(try fixture.info().appearance, .init(colorMode: "hs"))
        fixture.setAppearance("effect", effect: "Northern Lights")
        XCTAssertEqual(try fixture.info().appearance.effect, "Northern Lights")
        fixture.setAppearance("effect", effect: "*Dynamic*")
        XCTAssertNil(try fixture.info().appearance.effect)
        fixture.model = "NL29"
        XCTAssertFalse(try fixture.info().isShapes)
    }

    @MainActor
    func testPairingFetchesIdentityBeforeSavingCredential() async throws {
        let fixture = NanoleafFixture()
        let store = MemoryNanoleafCredentials()
        let client = makeClient(fixture, store: store)
        var updates: [String] = []
        client.onUpdate = { pairing, _ in updates.append(pairing.serial) }
        try await client.pair(endpoint: fixture.endpoint, serviceID: "bonjour-id")
        XCTAssertEqual(store.pairings.first?.serial, "SHAPES123")
        XCTAssertEqual(store.pairings.first?.serviceID, "bonjour-id")
        XCTAssertEqual(store.pairings.first?.token, "testToken123")
        XCTAssertEqual(updates, ["SHAPES123"])
        XCTAssertEqual(fixture.requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(fixture.requests.first?.url?.port, 16021)
        XCTAssertEqual(fixture.requests.last?.url?.path, "/api/v1/testToken123")
    }

    @MainActor
    func testPairingClosedAndWrongModelNeverSave() async throws {
        let fixture = NanoleafFixture()
        let store = MemoryNanoleafCredentials()
        let client = makeClient(fixture, store: store)
        fixture.nextStatus = 403
        do { try await client.pair(endpoint: fixture.endpoint); XCTFail("Expected closed pairing window") }
        catch { XCTAssertEqual(error as? NanoleafError, .pairingWindowClosed) }
        XCTAssertTrue(store.pairings.isEmpty)
        fixture.model = "NL29"
        do { try await client.pair(endpoint: fixture.endpoint); XCTFail("Expected unsupported model") }
        catch { XCTAssertEqual(error as? NanoleafError, .unsupportedModel) }
        XCTAssertTrue(store.pairings.isEmpty)
    }

    @MainActor
    func testKeychainFailureDoesNotPublishPairedDevice() async throws {
        let fixture = NanoleafFixture()
        let store = MemoryNanoleafCredentials()
        store.failSaving = true
        let client = makeClient(fixture, store: store)
        client.onUpdate = { _, _ in XCTFail("Pairing was not saved") }
        do { try await client.pair(endpoint: fixture.endpoint); XCTFail("Expected save failure") }
        catch { XCTAssertEqual(error as? NanoleafError, .storageFailure) }
    }

    @MainActor
    func testStateCommandsUseJSONAndRefreshAfterSuccess() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        try await client.pair(endpoint: fixture.endpoint)
        let updated = expectation(description: "Confirmed state fetched")
        client.onUpdate = { _, info in
            XCTAssertTrue(info.state.on.value)
            XCTAssertEqual(info.state.brightness.value, 27)
            XCTAssertEqual(info.state.hue.value, 180)
            updated.fulfill()
        }
        client.setState("SHAPES123", ["on": ["value": true]])
        client.setState("SHAPES123", NanoleafProtocol.color(hue: 0.5, saturation: 1, brightness: 0.27))
        await fulfillment(of: [updated], timeout: 2)
        let puts = fixture.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts.first?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(puts.first?.url?.path, "/api/v1/testToken123/state")
    }

    @MainActor
    func testLatestFrameWinsAndEffectClearsQueuedColor() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        try await client.pair(endpoint: fixture.endpoint)
        for index in 0..<100 {
            client.setState("SHAPES123", NanoleafProtocol.color(hue: 0.25, saturation: 1, brightness: Double(index) / 100), transient: true)
        }
        client.selectEffect("SHAPES123", name: "Northern Lights")
        let updated = expectation(description: "Effect selected")
        client.onUpdate = { _, info in
            XCTAssertEqual(info.appearance.effect, "Northern Lights")
            XCTAssertEqual(info.state.brightness.value, 99)
            updated.fulfill()
        }
        await fulfillment(of: [updated], timeout: 2)
        let puts = fixture.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        let body = try XCTUnwrap(puts.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["hue"])
        XCTAssertNil(json["sat"])
    }

    @MainActor
    func testAuthorizationFailureIsSpecificAndSanitized() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        try await client.pair(endpoint: fixture.endpoint)
        fixture.nextStatus = 401
        let failed = expectation(description: "Re-pair needed")
        client.onFailure = { serial, error in
            XCTAssertEqual(serial, "SHAPES123")
            XCTAssertEqual(error, .pairingRequired)
            XCTAssertFalse(error.localizedDescription.contains("testToken123"))
            failed.fulfill()
        }
        client.setState("SHAPES123", ["on": ["value": true]])
        await fulfillment(of: [failed], timeout: 2)
    }

    @MainActor
    func testPauseCancelsQueuedTraffic() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        try await client.pair(endpoint: fixture.endpoint)
        client.setState("SHAPES123", ["on": ["value": true]])
        client.pause()
        client.setState("SHAPES123", ["on": ["value": false]])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor
    func testManagerRoutesControlsAndConfirmsNanoleafState() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        let manager = makeManager(client)
        try await manager.pairNanoleaf(host: fixture.endpoint.host)
        let device = try XCTUnwrap(manager.devices.first)
        XCTAssertEqual(device.id, "nanoleaf:SHAPES123")
        XCTAssertEqual(device.brand, .nanoleaf)
        XCTAssertEqual(device.kelvinRange, 1200...6500)
        manager.setPower(device, on: true)
        manager.setBrightness(device, value: 0.42)
        manager.setColor(device, color: Color(hue: 0.5, saturation: 1, brightness: 0.2))
        try await waitUntil { manager.commandPendingIDs.isEmpty }
        XCTAssertEqual(try fixture.info().state.brightness.value, 42)
        XCTAssertEqual(try fixture.info().state.hue.value, 180)
        XCTAssertNotEqual(manager.commandState(for: device.id).phase, .failed)
        manager.setKelvin(device, kelvin: 9000)
        try await waitUntil { manager.commandPendingIDs.isEmpty }
        XCTAssertEqual(device.kelvin, 6500)
        XCTAssertEqual(try fixture.info().state.ct.value, 6500)
        XCTAssertEqual(device.nanoleafAppearance?.colorMode, "ct")
        client.pause()
    }

    @MainActor
    func testNativeEffectSurvivesScene() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        let manager = makeManager(client)
        try await manager.pairNanoleaf(host: fixture.endpoint.host)
        let device = try XCTUnwrap(manager.devices.first)
        manager.selectNanoleafEffect(device, name: "Northern Lights")
        try await waitUntil { manager.commandPendingIDs.isEmpty }
        let snap = DeviceSnapshot(isOn: true, brightness: 0.4, hue: 0.1, saturation: 1,
                                  nanoleafAppearance: device.nanoleafAppearance)
        let decoded = try JSONDecoder().decode(DeviceSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.nanoleafAppearance?.effect, "Northern Lights")
        manager.setColor(device, color: .red)
        try await waitUntil { manager.commandPendingIDs.isEmpty }
        manager.applyScene(LightingScene(name: "Nanoleaf", snapshots: [device.id: decoded]))
        try await waitUntil { manager.commandPendingIDs.isEmpty }
        XCTAssertEqual(try fixture.info().appearance.effect, "Northern Lights")
        XCTAssertEqual(try fixture.info().state.brightness.value, 40)
        client.pause()
    }

    @MainActor
    func testNativeWhiteModeSurvivesScene() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        let manager = makeManager(client)
        try await manager.pairNanoleaf(host: fixture.endpoint.host)
        let device = try XCTUnwrap(manager.devices.first)
        let snap = DeviceSnapshot(isOn: true, brightness: 0.32, hue: 0.4, saturation: 1, kelvin: 1800,
                                  nanoleafAppearance: .init(colorMode: "ct"))
        manager.applyScene(LightingScene(name: "Warm Shapes", snapshots: [device.id: snap]))
        try await waitUntil { manager.commandPendingIDs.isEmpty }
        XCTAssertEqual(try fixture.info().state.ct.value, 1800)
        XCTAssertEqual(try fixture.info().state.brightness.value, 32)
        XCTAssertTrue(manager.isWhiteMode(device.id))
        client.pause()
    }

    @MainActor
    func testNanoleafMusicUsesOwnRateLimitedTransport() async throws {
        let fixture = NanoleafFixture()
        let client = makeClient(fixture)
        let manager = makeManager(client)
        try await manager.pairNanoleaf(host: fixture.endpoint.host)
        let descriptor = try XCTUnwrap(manager.musicFixtureDescriptors(in: .all).first)
        XCTAssertEqual(descriptor.transport, .nanoleafLAN)
        XCTAssertEqual(descriptor.segmentCount, 0) // No layout reported, so the whole controller.
        XCTAssertEqual(MusicLightingRenderer.minimumInterval(for: .nanoleafLAN), 0.2)
        client.pause()
    }

    func testOldScenesDecodeAndExportsDoNotContainPairing() throws {
        let old = Data(#"{"isOn":true,"brightness":0.4,"hue":0.5,"saturation":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DeviceSnapshot.self, from: old).nanoleafAppearance)
        let state = PersistedApplicationState()
        let store = PersistenceStore(fileURL: URL(fileURLWithPath: "/unused-nanoleaf-test.json"))
        let export = String(decoding: try store.exportConfiguration(from: state), as: UTF8.self)
        XCTAssertFalse(export.contains("auth_token"))
        XCTAssertFalse(export.contains("testToken123"))
    }

    @MainActor
    private func makeClient(_ fixture: NanoleafFixture, store: MemoryNanoleafCredentials = MemoryNanoleafCredentials()) -> NanoleafClient {
        NanoleafURLProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NanoleafURLProtocol.self]
        // No event stream, a recording datagram sender and a fixed resolver:
        // nothing here may reach the network or a physical controller.
        return NanoleafClient(credentials: store, session: URLSession(configuration: configuration),
                              listensForEvents: false, datagrams: RecordingDatagrams(),
                              resolver: FixedResolver(address: "192.0.2.44"))
    }

    @MainActor
    private func makeManager(_ client: NanoleafClient) -> LightManager {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return LightManager(persistenceStore: PersistenceStore(fileURL: file), nanoleafClient: client)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Nanoleaf command confirmation")
    }
}

private final class MemoryNanoleafCredentials: NanoleafCredentialStoring {
    var pairings: [NanoleafPairing] = []
    var failSaving = false
    func load() throws -> [NanoleafPairing] { pairings }
    func save(_ pairings: [NanoleafPairing]) throws {
        if failSaving { throw NanoleafError.storageFailure }
        self.pairings = pairings
    }
}

private final class NanoleafFixture {
    let endpoint = try! NanoleafEndpoint(host: "shapes.local")
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var state: [String: Any] = ["on": ["value": false], "brightness": ["value": 80],
                                       "hue": ["value": 20], "sat": ["value": 80],
                                       "ct": ["value": 3500], "colorMode": "hs"]
    private var effect = "*Solid*"
    var model = "NL42"
    var nextStatus: Int?
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    func setAppearance(_ mode: String, effect: String) {
        lock.lock(); defer { lock.unlock() }
        state["colorMode"] = mode
        self.effect = effect
    }

    private func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["name": "Shapes", "serialNo": "SHAPES123", "model": model,
                                                     "state": state, "effects": ["select": effect, "effectsList": ["Northern Lights", "Forest"]]])
    }

    func info() throws -> NanoleafInfo {
        lock.lock(); defer { lock.unlock() }
        return try JSONDecoder().decode(NanoleafInfo.self, from: data())
    }

    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        var recordedRequest = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recordedRequest.httpBody = data
        }
        recorded.append(recordedRequest)
        if let code = nextStatus { nextStatus = nil; return (code, Data()) }
        if request.httpMethod == "POST" { return (200, Data(#"{"auth_token":"testToken123"}"#.utf8)) }
        if request.httpMethod == "PUT", let body = recordedRequest.httpBody,
           let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let select = json["select"] as? String { effect = select; state["colorMode"] = "effect" }
            else {
                state.merge(json) { _, new in new }
                if json["hue"] != nil { state["colorMode"] = "hs"; effect = "*Solid*" }
                if json["ct"] != nil { state["colorMode"] = "ct"; effect = "*Solid*" }
            }
            return (204, Data())
        }
        return (200, try data())
    }
}

private final class NanoleafURLProtocol: URLProtocol {
    static var fixture: NanoleafFixture!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.fixture.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
