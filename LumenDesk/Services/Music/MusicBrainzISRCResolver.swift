import Foundation

/// Resolves a playing track's ISRC from the metadata Now Playing already
/// reports, so Music Mode can fetch its precomputed iLightShow map. Tests
/// inject a stub.
protocol ISRCResolving: Sendable {
    /// The track's ISRC, or nil when it can't be resolved.
    func isrc(title: String, artist: String) async -> String?
}

/// `ISRCResolving` over the public MusicBrainz web service — title + artist →
/// recording → ISRC, no account or device entitlement required.
///
/// Two requests: a recording search, then a lookup of that recording's ISRCs.
/// Results (hits and definitive misses) are cached per title/artist, and the
/// actor serialises requests and spaces them out to respect MusicBrainz's
/// one-request-per-second guidance. A transport error is not cached, so a
/// later track change can retry.
///
/// Privacy: this sends the playing track's title and artist to musicbrainz.org.
/// It only runs when the experimental server-analysis setting is on.
actor MusicBrainzISRCResolver: ISRCResolving {
    private let session: URLSession
    private let baseURL: URL
    private let userAgent: String
    private let minRequestInterval: TimeInterval

    private var cache: [String: String?] = [:]
    private var lastRequestAt: Date?

    init(
        baseURL: URL = URL(string: "https://musicbrainz.org")!,
        session: URLSession? = nil,
        minRequestInterval: TimeInterval = 1.1
    ) {
        self.baseURL = baseURL
        self.minRequestInterval = minRequestInterval
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        // A plain app/version User-Agent — no personal contact details.
        self.userAgent = "LumenDesk/\(version) ( music-mode )"
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func isrc(title: String, artist: String) async -> String? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let key = cacheKey(trimmedTitle, artist)
        if let cached = cache[key] { return cached } // includes a cached miss (nil)
        do {
            let resolved = try await lookup(title: trimmedTitle, artist: artist)
            cache[key] = resolved
            return resolved
        } catch {
            // Transient (network / rate limit); don't poison the cache.
            return nil
        }
    }

    // MARK: - MusicBrainz

    private func lookup(title: String, artist: String) async throws -> String? {
        var query = "recording:\"\(lucene(title))\""
        let cleanArtist = lucene(artist)
        if !cleanArtist.isEmpty { query += " AND artist:\"\(cleanArtist)\"" }

        guard let searchURL = url(path: "ws/2/recording", items: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "fmt", value: "json"),
        ]) else { return nil }
        let search = try await getJSON(searchURL)
        guard let recordings = search["recordings"] as? [[String: Any]],
              let id = recordings.first?["id"] as? String else {
            return nil // definitive: no recording matched
        }

        guard let lookupURL = url(path: "ws/2/recording/\(id)", items: [
            URLQueryItem(name: "inc", value: "isrcs"),
            URLQueryItem(name: "fmt", value: "json"),
        ]) else { return nil }
        let detail = try await getJSON(lookupURL)
        guard let isrcs = detail["isrcs"] as? [String], let first = isrcs.first else {
            return nil // definitive: recording carries no ISRC
        }
        return first.uppercased()
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        await throttle()
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        lastRequestAt = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    private func throttle() async {
        guard minRequestInterval > 0, let last = lastRequestAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        if elapsed < minRequestInterval {
            try? await Task.sleep(nanoseconds: UInt64((minRequestInterval - elapsed) * 1_000_000_000))
        }
    }

    private func url(path: String, items: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = items
        return components.url
    }

    private func cacheKey(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{1}\(artist.lowercased())"
    }

    /// Strips the Lucene special characters that would break the query string.
    private func lucene(_ text: String) -> String {
        text.components(separatedBy: CharacterSet(charactersIn: "\"\\+-!(){}[]^~*?:/&|")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
