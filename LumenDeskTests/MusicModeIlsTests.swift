import CryptoKit
import XCTest
@testable import LumenDesk

/// The iLightShow-backed path for Music Mode: the beat-map provider's caching
/// and fail-closed behaviour, and the coordinator adopting a server map over
/// the live learner.
final class MusicModeIlsTests: XCTestCase {
    // MARK: - Provider

    func testProviderReturnsMapAndCaches() async {
        let fetcher = CountingFetcher(result: .success(Self.playableAnalysis()))
        let provider = IlsBeatMapProvider(fetcher: fetcher, prepare: {})
        let first = await provider.beatMap(forISRC: "USUM71000123")
        let second = await provider.beatMap(forISRC: "USUM71000123")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 1, "the second lookup should hit the cache")
    }

    func testProviderDoesNotRefetchAMiss() async {
        // An analysis with no beats yields no playable map.
        let fetcher = CountingFetcher(result: .success(IlsAnalysis()))
        let provider = IlsBeatMapProvider(fetcher: fetcher, prepare: {})
        let first = await provider.beatMap(forISRC: "USUM71000123")
        let second = await provider.beatMap(forISRC: "USUM71000123")
        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 1, "a miss should be remembered, not re-fetched")
    }

    func testProviderTripsBreakerOnPrepareFailure() async {
        let fetcher = CountingFetcher(result: .success(Self.playableAnalysis()))
        let provider = IlsBeatMapProvider(fetcher: fetcher, prepare: { throw TestError.boom })
        let a = await provider.beatMap(forISRC: "A")
        let b = await provider.beatMap(forISRC: "B")
        XCTAssertNil(a)
        XCTAssertNil(b)
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 0, "enrolment failure must stop all fetches for the session")
    }

    func testProviderFetchesPerISRC() async {
        let fetcher = CountingFetcher(result: .success(Self.playableAnalysis()))
        let provider = IlsBeatMapProvider(fetcher: fetcher, prepare: {})
        let a = await provider.beatMap(forISRC: "A")
        let b = await provider.beatMap(forISRC: "B")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 2)
    }

    // MARK: - Coordinator adoption (following needs Now Playing: macOS only)
    #if os(macOS)
    func testCoordinatorAdoptsServerMap() {
        let time = 100.0
        let coord = BeatMapCoordinator(now: { time })
        coord.beginFollowing(startMonitor: false)
        let sample = NowPlayingSample(app: .music, trackID: "t1", title: "Song", artist: "Artist",
                                      duration: 120, position: 0, isPlaying: true, sampledAt: time)
        coord.receive(sample)
        let key = sample.app.trackKey(sample.trackID)
        XCTAssertEqual(coord.serverMapTargetKey(), key)

        coord.adoptServerMap(Self.playableMap(tempo: 128), key: key)
        XCTAssertNil(coord.serverMapTargetKey(), "the track is now server-mapped")
        guard case let .following(_, _, tempo) = coord.status else {
            return XCTFail("expected a following status, got \(coord.status)")
        }
        XCTAssertEqual(tempo, 128, accuracy: 0.001)
    }

    func testCoordinatorIgnoresServerMapForAStaleTrack() {
        var time = 100.0
        let coord = BeatMapCoordinator(now: { time })
        coord.beginFollowing(startMonitor: false)
        var sample = NowPlayingSample(app: .music, trackID: "t1", title: "A", artist: "x",
                                      duration: 120, position: 0, isPlaying: true, sampledAt: time)
        coord.receive(sample)
        let staleKey = sample.app.trackKey(sample.trackID)

        // The track changes before the (slow) fetch returns.
        time = 110; sample.trackID = "t2"; sample.sampledAt = time
        coord.receive(sample)
        coord.adoptServerMap(Self.playableMap(tempo: 99), key: staleKey)
        XCTAssertEqual(coord.serverMapTargetKey(), sample.app.trackKey("t2"),
                       "a map for the previous track must not be adopted")
    }

    func testTrackChangesFireOnTrackChanged() {
        let coord = BeatMapCoordinator(now: { 0 })
        var resets = 0
        coord.onTrackChanged = { resets += 1 }
        coord.beginFollowing(startMonitor: false)
        let first = NowPlayingSample(app: .music, trackID: "t1", title: "A", artist: "x",
                                     duration: 120, position: 0, isPlaying: true, sampledAt: 0)
        coord.receive(first)             // new track
        var second = first
        second.trackID = "t2"
        coord.receive(second)            // changed track
        coord.receive(nil)               // stopped
        XCTAssertEqual(resets, 3)
    }
    #endif

    // MARK: - Authorized dev provisioning

    func testProvisioningRequestAndDevCredentialImport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = IlsDPoPKey(privateKey: P256.Signing.PrivateKey())
        let client = IlsClient(configuration: try IlsClient.Configuration(key: key, supportDirectory: dir))

        // The request carries the public key + thumbprint and no secret.
        let request = await client.provisioningRequest()
        XCTAssertEqual(request.keyThumbprint, key.thumbprint)
        XCTAssertEqual(request.publicKey, key.jwkDictionary)
        XCTAssertEqual(request.platform, "macos")
        let path = try await client.writeProvisioningRequest()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        // A credential dropped by the operator is imported and the plaintext
        // file is deleted; the token is bound to our key.
        let credential = IlsDevCredential(installationId: "inst-1", accessToken: "tok-1",
                                          dpopNonce: "nonce-1", expiresAt: Date.now.addingTimeInterval(3600))
        let credURL = dir.appendingPathComponent("ils-dev-credential.json")
        try JSONEncoder().encode(credential).write(to: credURL)

        let loaded = await client.loadDevCredentialIfPresent()
        XCTAssertTrue(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credURL.path),
                       "the secret credential file is removed after import")
        let token = await client.token
        XCTAssertEqual(token?.accessToken, "tok-1")
        XCTAssertEqual(token?.keyThumbprint, key.thumbprint)
        XCTAssertTrue(token?.isCurrent ?? false)
    }

    // MARK: - MusicBrainz resolver

    func testMusicBrainzResolver() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let resolver = MusicBrainzISRCResolver(baseURL: URL(string: "https://mb.test")!,
                                               session: session, minRequestInterval: 0)

        // Hit: search finds a recording, lookup returns its ISRC (uppercased).
        StubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("query=") {
                return (Data(#"{"recordings":[{"id":"rec-1","title":"Song"}]}"#.utf8), 200)
            }
            return (Data(#"{"id":"rec-1","isrcs":["usum71000123"]}"#.utf8), 200)
        }
        let hit = await resolver.isrc(title: "Song", artist: "Artist")
        XCTAssertEqual(hit, "USUM71000123")

        // Miss: no recording matched → nil.
        StubURLProtocol.handler = { _ in (Data(#"{"recordings":[]}"#.utf8), 200) }
        let noMatch = await resolver.isrc(title: "Unknown", artist: "Nobody")
        XCTAssertNil(noMatch)

        // Matched recording that carries no ISRC → nil.
        StubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("query=") {
                return (Data(#"{"recordings":[{"id":"rec-2"}]}"#.utf8), 200)
            }
            return (Data(#"{"id":"rec-2","isrcs":[]}"#.utf8), 200)
        }
        let noISRC = await resolver.isrc(title: "Instrumental", artist: "Someone")
        XCTAssertNil(noISRC)
    }

    // MARK: - Fixtures

    enum TestError: Error { case boom }

    /// Counts fetches so cache/miss/breaker behaviour is observable.
    actor CountingFetcher: IlsAnalysisFetching {
        private(set) var calls = 0
        private let result: Result<IlsAnalysis, Error>
        init(result: Result<IlsAnalysis, Error>) { self.result = result }
        func analysis(for isrc: String) async throws -> IlsAnalysis {
            calls += 1
            return try result.get()
        }
    }

    /// A steady 120 BPM analysis that maps to a playable `BeatMap`.
    static func playableAnalysis() -> IlsAnalysis {
        var analysis = IlsAnalysis()
        analysis.duration = 10
        analysis.tempo = 120
        for frame in stride(from: 0, through: 1000, by: 50) {
            var item = IlsAnalysis.IlsItem()
            item.frameInTrack = frame
            item.beat = true
            item.drum = true
            analysis.items.append(item)
        }
        return analysis
    }

    static func playableMap(tempo: Double) -> BeatMap {
        let beats = stride(from: 0.0, to: 10.0, by: 0.5).map { $0 }
        return BeatMap(version: BeatMap.currentVersion, duration: 10, tempo: tempo, beats: beats,
                       downbeatOffset: 0, barEnergy: [0.5, 0.6], envelope: [0, 1, 0, 1], confidence: 1)
    }
}

/// Returns canned HTTP bodies so the resolver's parsing is tested without the
/// network. Only the resolver test mutates `handler`.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, Int))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (data, status) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
