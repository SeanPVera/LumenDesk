import Foundation

/// Errors from the iLightShow client.
enum IlsError: Error, LocalizedError {
    case notEnrolled
    case challengeFailed(status: Int, body: String)
    case enrollFailed(status: Int, body: String)
    case analysisFailed(status: Int, body: String)
    case noAnalysisFound
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notEnrolled:
            return "Not enrolled with the iLightShow API."
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
final class IlsClient: @unchecked Sendable {
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
            appVersion: String = "2.1",
            appBuild: Int = 291,
            os: String = "mac",
            key: IlsDPoPKey? = nil,
            session: URLSession = .shared
        ) throws {
            self.baseURL = baseURL
            self.platform = platform
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.os = os
            self.key = try key ?? IlsDPoPKey()
            self.session = session
        }
    }

    struct Token {
        let installationId: String
        let accessToken: String
        let dpopNonce: String
        let expiresAt: Date?

        var isCurrent: Bool {
            guard let expiresAt else { return true }
            return Date.now < expiresAt.addingTimeInterval(30)
        }
    }

    private static let tokenStorageKey = "com.lumendesk.ilightshow.token"

    private let config: Configuration
    private(set) var token: Token?

    /// Creates a client with default configuration.
    convenience init() throws {
        try self.init(configuration: Configuration())
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
              let dpopNonce = enrollment["dpop_nonce"] as? String ?? enrollment["dpopNonce"] as? String
        else {
            throw IlsError.enrollFailed(status: enrollStatus, body: String(data: enrollData, encoding: .utf8) ?? "no HTTP response")
        }

        var expiresAt: Date?
        if let unix = enrollment["expires_at"] as? Double {
            expiresAt = Date(timeIntervalSince1970: unix)
        } else if let iso = enrollment["expires_at"] as? String {
            expiresAt = Self.iso8601.date(from: iso)
        }

        let newToken = Token(
            installationId: installationId,
            accessToken: accessToken,
            dpopNonce: dpopNonce,
            expiresAt: expiresAt
        )
        token = newToken
        persistToken()
        return newToken
    }

    /// Restores the persisted token from a previous run, if still valid.
    func restoreToken() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.tokenStorageKey),
            let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let installationId = stored["installationId"] as? String,
            let accessToken = stored["accessToken"] as? String,
            let dpopNonce = stored["dpopNonce"] as? String
        else { return }
        let candidate = Token(
            installationId: installationId,
            accessToken: accessToken,
            dpopNonce: dpopNonce,
            expiresAt: (stored["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
        if candidate.isCurrent { token = candidate }
    }

    private func persistToken() {
        guard let token else { return }
        let stored: [String: Any] = [
            "installationId": token.installationId,
            "accessToken": token.accessToken,
            "dpopNonce": token.dpopNonce,
            "expiresAt": (token.expiresAt?.timeIntervalSince1970).map { $0 } ?? NSNull(),
        ]
        UserDefaults.standard.set(try? JSONSerialization.data(withJSONObject: stored), forKey: Self.tokenStorageKey)
    }

    // MARK: - Analysis

    /// Fetches and decrypts the analysis bundle for an ISRC.
    ///
    /// The server returns 201 with the bundle when an analysis exists and
    /// 200 with an empty body otherwise (the app's behavior, `C0658l`).
    func analysis(for isrc: String) async throws -> IlsAnalysis {
        guard let token, token.isCurrent else { throw IlsError.notEnrolled }
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
        let status = http?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw IlsError.analysisFailed(status: status, body: String(data: data, encoding: .utf8) ?? "no HTTP response")
        }
        guard data.count >= 12 + 16 else { throw IlsError.noAnalysisFound }
        do {
            return try IlsCrypto.decodeBundle(Array(data))
        } catch let error as IlsCrypto.BundleError {
            throw IlsError.decoding("\(error)")
        }
    }

    // MARK: - Helpers

    /// The same client headers the app sends on every request.
    private func addClientHeaders(_ request: inout URLRequest) {
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ils-client-request-id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-ils-client-attempt-id")
        request.setValue("0", forHTTPHeaderField: "x-ils-client-attempt")
        request.setValue(String(config.appBuild), forHTTPHeaderField: "x-ils-appbuild")
        request.setValue(config.os, forHTTPHeaderField: "x-ils-os")
        request.setValue("LumenDesk/\(config.appVersion)", forHTTPHeaderField: "User-Agent")
    }

    private static let iso8601 = ISO8601DateFormatter()

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IlsError.decoding("unexpected JSON shape")
        }
        return object
    }
}
