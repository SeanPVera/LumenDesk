import Foundation

/// Errors from the iLightShow client.
enum IlsError: Error, LocalizedError {
    case notEnrolled
    case invalidISRC(String)
    case responseTooLarge(Int)
    case challengeFailed(status: Int, body: String)
    case enrollFailed(status: Int, body: String)
    case analysisFailed(status: Int, body: String)
    case noAnalysisFound
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notEnrolled:
            return "Not enrolled with the iLightShow API."
        case .invalidISRC(let value):
            return "Not a valid ISRC: \(value)"
        case .responseTooLarge(let bytes):
            return "Analysis response too large (\(bytes) bytes)."
        case .challengeFailed(let status, let body):
            return "Challenge failed (\(status)): \(body)"
        case .enrollFailed(let status, let body):
            return "Enrollment failed (\(status)): \(body)"
        case .analysisFailed(let status, let body):
            return "Analysis request failed (\(status)): \(body)"
        case .noAnalysisFound:
            return "No analysis available for this ISRC."
        case .decoding(let message):
            return "Decoding failed: \(message)"
        }
    }
}

/// A client for the iLightShow analysis API.
///
/// The flow (verified against the 4.0.0-beta APK, `C0679t`):
/// 1. `POST /ils/app-auth/challenge` — present our P-256 JWK; the server
///    answers with the enrollment challenge (the DPoP `nonce`).
/// 2. `POST /ils/app-auth/enroll/{platform}` — the stock app sends a Play
///    Integrity token here; on macOS we use the DPoP-only "Option A"
///    variant (the backend patch ships with this PR).
/// 3. `GET /ils/v3/isrc/{isrc}` — DPoP-authenticated; the body is the
///    encrypted bundle opened by `IlsCrypto`.
///
/// An `actor` so the mutable token/nonce state is never touched by two
/// overlapping requests at once.
actor IlsClient {
    struct Configuration {
        var baseURL: URL
        var platform: String
        var appVersion: String
        var appBuild: Int
        var os: String
        let key: IlsDPoPKey
        let session: URLSession

        init(
            baseURL: URL = URL(string: "https://api.ilightshow.app")!,
            platform: String = "macos",
            appVersion: String = Configuration.bundleAppVersion,
            appBuild: Int = Configuration.bundleAppBuild,
            os: String = Configuration.defaultOS,
            key: IlsDPoPKey? = nil,
            session: URLSession? = nil
        ) throws {
            self.baseURL = baseURL
            self.platform = platform
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.os = os
            self.key = try key ?? IlsDPoPKey()
            self.session = session ?? Configuration.makeSession()
        }

        /// `CFBundleShortVersionString`, with a harmless fallback for tests.
        static var bundleAppVersion: String {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        }

        /// `CFBundleVersion`, with a harmless fallback for tests.
        static var bundleAppBuild: Int {
            Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        }

        static var defaultOS: String {
            #if os(macOS)
            return "macos"
            #else
            return "ios"
            #endif
        }

        /// A session with finite timeouts, so a stalled request cannot hang
        /// the music path forever (the default `.shared` waits indefinitely).
        static func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }
    }

    struct Token: Codable {
        let installationId: String
        let accessToken: String
        var dpopNonce: String
        let expiresAt: Date?
        /// Thumbprint of the DPoP key this token was issued against.
        let keyThumbprint: String

        /// Expires 30 s early as a clock-skew buffer.
        var isCurrent: Bool {
            guard let expiresAt else { return true }
            return Date.now < expiresAt.addingTimeInterval(-30)
        }
    }

    private static let tokenAccount = "com.lumendesk.ilightshow.token"
    /// Analysis bundles are a few hundred KB; reject anything that could be a
    /// decompression-bomb feed before it reaches GCM/Brotli.
    private static let maxBundleBytes = 8 * 1024 * 1024

    private let config: Configuration
    private(set) var token: Token?

    /// Creates a client with default configuration.
    init() throws {
        self.config = try Configuration()
    }

    init(configuration: Configuration) {
        self.config = configuration
    }

    // MARK: - Enrollment

    /// Runs challenge → enroll and stores the resulting token.
    @discardableResult
    func enroll() async throws -> Token {
        // 1. Challenge — present our DPoP key.
        let challengeURL = config.baseURL.appendingPathComponent("ils/app-auth/challenge")
        var challengeRequest = URLRequest(url: challengeURL)
        challengeRequest.httpMethod = "POST"
        challengeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addClientHeaders(&challengeRequest)
        challengeRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "platform": config.platform,
            "operation": "enroll",
            "public_key": config.key.jwkDictionary,
            "metadata": [
                "appBuild": config.appBuild,
                "appVersion": config.appVersion,
                "os": config.os,
            ],
        ])

        let (challengeData, challengeResponse) = try await config.session.data(for: challengeRequest)
        let challengeHTTP = challengeResponse as? HTTPURLResponse
        let challengeStatus = challengeHTTP?.statusCode ?? -1
        guard (200..<300).contains(challengeStatus),
              let challenge = try? Self.json(challengeData),
              let id = challenge["challenge_id"] as? String ?? challenge["challengeId"] as? String,
              let nonce = challenge["challenge"] as? String ?? challenge["nonce"] as? String
        else {
            throw IlsError.challengeFailed(status: challengeStatus, body: String(data: challengeData, encoding: .utf8) ?? "no HTTP response")
        }

        // 2. Enrollment — DPoP-only (Option A).
        let enrollURL = config.baseURL.appendingPathComponent("ils/app-auth/enroll/\(config.platform)")
        var enrollRequest = URLRequest(url: enrollURL)
        enrollRequest.httpMethod = "POST"
        enrollRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addClientHeaders(&enrollRequest)
        enrollRequest.setValue(
            try IlsDPoP.proof(key: config.key, method: "POST", url: enrollURL.absoluteString, nonce: nonce),
            forHTTPHeaderField: "DPoP"
        )
        enrollRequest.httpBody = try JSONSerialization.data(withJSONObject: ["challenge_id": id])

        let (enrollData, enrollResponse) = try await config.session.data(for: enrollRequest)
        let enrollHTTP = enrollResponse as? HTTPURLResponse
        let enrollStatus = enrollHTTP?.statusCode ?? -1
        guard (200..<300).contains(enrollStatus),
              let enrollment = try? Self.json(enrollData),
              let installationId = enrollment["installation_id"] as? String ?? enrollment["installationId"] as? String,
              let accessToken = enrollment["access_token"] as? String ?? enrollment["accessToken"] as? String,
              let dpopNonce = enrollment["dpop_nonce"] as? String
                ?? enrollment["dpopNonce"] as? String
                ?? enrollHTTP?.value(forHTTPHeaderField: "DPoP-Nonce")
        else {
            throw IlsError.enrollFailed(status: enrollStatus, body: String(data: enrollData, encoding: .utf8) ?? "no HTTP response")
        }

        let expiresAt = Self.parseExpiry(enrollment["expires_at"] ?? enrollment["expiresAt"])

        let newToken = Token(
            installationId: installationId,
            accessToken: accessToken,
            dpopNonce: dpopNonce,
            expiresAt: expiresAt,
            keyThumbprint: config.key.thumbprint
        )
        token = newToken
        persistToken()
        return newToken
    }

    /// Restores the persisted token from a previous run, if still valid and
    /// bound to the current DPoP key.
    func restoreToken() {
        guard let data = IlsKeychain.load(account: Self.tokenAccount, service: IlsDPoPKey.service),
              let candidate = try? JSONDecoder().decode(Token.self, from: data)
        else { return }
        // A token issued against a different key (e.g. the key was
        // regenerated after a Keychain miss) is useless — discard it.
        guard candidate.keyThumbprint == config.key.thumbprint else {
            IlsKeychain.delete(account: Self.tokenAccount, service: IlsDPoPKey.service)
            return
        }
        if candidate.isCurrent { token = candidate }
    }

    private func persistToken() {
        guard let token, let data = try? JSONEncoder().encode(token) else { return }
        IlsKeychain.save(data, account: Self.tokenAccount, service: IlsDPoPKey.service)
    }

    // MARK: - Analysis

    /// Fetches and decrypts the analysis bundle for an ISRC.
    ///
    /// `201` carries the bundle; `200` means no analysis exists. A single
    /// `401` is recovered from by refreshing the `DPoP-Nonce` (and
    /// re-enrolling when the token has expired) and retrying once.
    func analysis(for rawISRC: String) async throws -> IlsAnalysis {
        let isrc = try Self.validatedISRC(rawISRC)
        guard token != nil else { throw IlsError.notEnrolled }
        if token?.isCurrent == false { try await enroll() }

        var attempts = 0
        while true {
            attempts += 1
            guard let current = token else { throw IlsError.notEnrolled }
            let (data, http) = try await performAnalysisRequest(isrc: isrc, token: current)
            let status = http?.statusCode ?? -1

            if status == 401, attempts < 2 {
                var recovered = false
                if let nonce = http?.value(forHTTPHeaderField: "DPoP-Nonce") {
                    token?.dpopNonce = nonce
                    persistToken()
                    recovered = true
                }
                if Self.indicatesExpiredToken(http: http, body: data) {
                    try await enroll()
                    recovered = true
                }
                if recovered { continue }
                throw IlsError.analysisFailed(status: status, body: String(data: data, encoding: .utf8) ?? "no HTTP response")
            }

            switch status {
            case 201:
                guard data.count <= Self.maxBundleBytes else { throw IlsError.responseTooLarge(data.count) }
                guard data.count >= 12 + 16 else { throw IlsError.noAnalysisFound }
                do {
                    return try IlsCrypto.decodeBundle(Array(data))
                } catch let error as IlsCrypto.BundleError {
                    throw IlsError.decoding("\(error)")
                }
            case 200:
                throw IlsError.noAnalysisFound
            default:
                throw IlsError.analysisFailed(status: status, body: String(data: data, encoding: .utf8) ?? "no HTTP response")
            }
        }
    }

    private func performAnalysisRequest(isrc: String, token: Token) async throws -> (Data, HTTPURLResponse?) {
        let url = config.baseURL.appendingPathComponent("ils/v3/isrc/\(isrc)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DPoP \(token.accessToken)", forHTTPHeaderField: "Authorization")
        addClientHeaders(&request)
        request.setValue(
            try IlsDPoP.proof(
                key: config.key,
                method: "GET",
                url: url.absoluteString,
                nonce: token.dpopNonce,
                accessToken: token.accessToken
            ),
            forHTTPHeaderField: "DPoP"
        )

        let (data, response) = try await config.session.data(for: request)
        let http = response as? HTTPURLResponse
        if let expected = http?.expectedContentLength, expected > Int64(Self.maxBundleBytes) {
            throw IlsError.responseTooLarge(Int(clamping: expected))
        }
        return (data, http)
    }

    // MARK: - Helpers

    /// A valid ISRC is two letters, three alphanumerics, seven digits — 12
    /// characters total. Rejecting anything else keeps `/`, `..` and spaces
    /// out of the request path, and the uppercased form matches the `htu` the
    /// server signs over.
    static func validatedISRC(_ raw: String) throws -> String {
        let candidate = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let pattern = "^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"
        guard candidate.range(of: pattern, options: .regularExpression) != nil else {
            throw IlsError.invalidISRC(raw)
        }
        return candidate
    }

    /// Whether a 401 is a token-expiry signal (as opposed to a stale nonce),
    /// read from `WWW-Authenticate` or an `{"error": …}` body.
    private static func indicatesExpiredToken(http: HTTPURLResponse?, body: Data) -> Bool {
        if let header = http?.value(forHTTPHeaderField: "WWW-Authenticate"),
           header.localizedCaseInsensitiveContains("token_expired") {
            return true
        }
        if let json = try? json(body), let error = json["error"] as? String {
            return error == "token_expired"
        }
        return false
    }

    /// Parses an `expires_at` that may be a UNIX time or an ISO-8601 string
    /// (with or without fractional seconds). The format styles are value
    /// types, so this is safe to call from concurrent requests.
    static func parseExpiry(_ value: Any?) -> Date? {
        if let unix = value as? Double { return Date(timeIntervalSince1970: unix) }
        if let unix = value as? Int { return Date(timeIntervalSince1970: Double(unix)) }
        guard let string = value as? String else { return nil }
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? fractional.parse(string)
    }

    /// The same client headers the app sends on every request.
    private func addClientHeaders(_ request: inout URLRequest) {
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ils-client-request-id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ils-client-attempt-id")
        request.setValue("0", forHTTPHeaderField: "x-ils-client-attempt")
        request.setValue(String(config.appBuild), forHTTPHeaderField: "x-ils-appbuild")
        request.setValue(config.os, forHTTPHeaderField: "x-ils-os")
        request.setValue("LumenDesk/\(config.appVersion)", forHTTPHeaderField: "User-Agent")
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IlsError.decoding("unexpected JSON shape")
        }
        return object
    }
}
