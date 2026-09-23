import Foundation

/// Nanoleaf puts its credential in the URL path. Never follow redirects or
/// surface raw networking errors (which can include that URL) to the user.
private final class NanoleafSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class NanoleafClient: NSObject {
    var onCandidates: (([NanoleafCandidate]) -> Void)?
    var onUpdate: ((NanoleafPairing, NanoleafInfo) -> Void)?
    var onFailure: ((String, NanoleafError) -> Void)?
    var onDiscoveryError: ((String) -> Void)?

    private let credentials: NanoleafCredentialStoring
    private let session: URLSession
    private var pairings: [String: NanoleafPairing] = [:]
    private var candidates: [String: NanoleafCandidate] = [:]
    private var services: [NetService] = []
    private var browser: NetServiceBrowser?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pending: [String: Pending] = [:]
    private var generation = 0
    private var paused = false
    private var pairingInProgress = false
    private var didLoadCredentials = false

    /// A single in-flight request per controller with one coalesced successor.
    /// Slow HTTP controllers cannot accumulate hundreds of stale music frames.
    private struct Pending {
        var state: [String: Any] = [:]
        var effect: String?
        var refresh = false
    }

    init(credentials: NanoleafCredentialStoring = NanoleafCredentialStore(), session: URLSession? = nil) {
        self.credentials = credentials
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(configuration: configuration, delegate: NanoleafSessionDelegate(), delegateQueue: nil)
        }
        super.init()
    }

    func discover() {
        reconnect()
        browser?.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        candidates.removeAll()
        publishCandidates()
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: NanoleafProtocol.serviceType, inDomain: "local.")
    }

    func reconnect() {
        paused = false
        do { try loadCredentials() }
        catch { onDiscoveryError?(NanoleafError.storageFailure.localizedDescription); return }
        for serial in pairings.keys { refresh(serial) }
    }

    private func loadCredentials() throws {
        guard !didLoadCredentials else { return }
        for pairing in try credentials.load() { pairings[pairing.serial] = pairing }
        didLoadCredentials = true
    }

    /// Demo Mode also cancels queued HTTP traffic, not just UI callbacks.
    func pause() {
        paused = true
        generation += 1
        browser?.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        pending.removeAll()
    }

    func pair(endpoint: NanoleafEndpoint, serviceID: String? = nil) async throws {
        guard !paused, !pairingInProgress else { throw NanoleafError.unavailable }
        try loadCredentials()
        pairingInProgress = true
        defer { pairingInProgress = false }
        let generation = self.generation
        let data = try await request(endpoint: endpoint, path: "/api/v1/new", method: "POST", pairing: true)
        struct Token: Decodable { let auth_token: String }
        guard let token = try? JSONDecoder().decode(Token.self, from: data).auth_token,
              !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw NanoleafError.invalidResponse
        }
        let info = try await readInfo(endpoint: endpoint, token: token)
        guard info.isShapes else { throw NanoleafError.unsupportedModel }
        guard !info.serialNo.isEmpty, generation == self.generation, !paused else {
            throw NanoleafError.unavailable
        }
        // A manual pairing may follow discovery. Retain its service ID so a
        // later DHCP address change can reconnect without another button press.
        let resolvedServiceID = serviceID ?? candidates.values.first(where: { $0.endpoint == endpoint })?.id
        let pairing = NanoleafPairing(serial: info.serialNo, serviceID: resolvedServiceID,
                                     name: info.name, endpoint: endpoint, token: token)
        var next = pairings
        next[info.serialNo] = pairing
        try credentials.save(Array(next.values))
        pairings = next
        publishCandidates()
        onUpdate?(pairing, info)
    }

    func refresh(_ serial: String) {
        guard !paused, pairings[serial] != nil else { return }
        pending[serial, default: Pending()].refresh = true
        drain(serial)
    }

    func setState(_ serial: String, _ state: [String: Any], transient: Bool = false) {
        guard !paused, pairings[serial] != nil else { return }
        var next = pending[serial] ?? Pending()
        if state["hue"] != nil || state["sat"] != nil {
            next.state.removeValue(forKey: "ct")
            next.effect = nil
        } else if state["ct"] != nil {
            next.state.removeValue(forKey: "hue")
            next.state.removeValue(forKey: "sat")
            next.effect = nil
        }
        next.state.merge(state) { _, new in new }
        next.refresh = next.refresh || !transient
        pending[serial] = next
        drain(serial)
    }

    func selectEffect(_ serial: String, name: String) {
        guard !paused, pairings[serial] != nil else { return }
        var next = pending[serial] ?? Pending()
        next.state.removeValue(forKey: "hue")
        next.state.removeValue(forKey: "sat")
        next.state.removeValue(forKey: "ct")
        next.effect = name
        next.refresh = true
        pending[serial] = next
        drain(serial)
    }

    private func drain(_ serial: String) {
        guard tasks[serial] == nil, !paused else { return }
        let generation = self.generation
        tasks[serial] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.tasks.removeValue(forKey: serial) } }
            while !Task.isCancelled, generation == self.generation,
                  let command = self.pending.removeValue(forKey: serial),
                  let pairing = self.pairings[serial] {
                do {
                    if !command.state.isEmpty {
                        _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/state",
                                                   method: "PUT", body: command.state)
                    }
                    if let effect = command.effect {
                        try Task.checkCancellation()
                        _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                                   method: "PUT", body: ["select": effect])
                    }
                    if command.refresh {
                        let info = try await self.readInfo(endpoint: pairing.endpoint, token: pairing.token)
                        guard generation == self.generation, !Task.isCancelled else { return }
                        guard info.serialNo == serial, info.isShapes else { throw NanoleafError.invalidResponse }
                        self.onUpdate?(pairing, info)
                    }
                } catch {
                    guard generation == self.generation, !Task.isCancelled else { return }
                    let failure = error as? NanoleafError ?? .unavailable
                    if failure == .pairingRequired { self.pending.removeValue(forKey: serial) }
                    self.onFailure?(serial, failure)
                }
            }
        }
    }

    private func readInfo(endpoint: NanoleafEndpoint, token: String) async throws -> NanoleafInfo {
        let data = try await request(endpoint: endpoint, path: "/api/v1/\(token)", method: "GET")
        guard let info = try? JSONDecoder().decode(NanoleafInfo.self, from: data) else {
            throw NanoleafError.invalidResponse
        }
        return info
    }

    private func request(endpoint: NanoleafEndpoint, path: String, method: String,
                         body: [String: Any]? = nil, pairing: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: try endpoint.url(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw NanoleafError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw NanoleafError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw pairing ? NanoleafError.pairingWindowClosed : .pairingRequired
        default: throw NanoleafError.http(http.statusCode)
        }
    }

    private func publishCandidates() {
        onCandidates?(candidates.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }
}

extension NanoleafClient: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !paused, browser === self.browser else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !paused, services.contains(where: { $0 === sender }), let host = sender.hostName,
              let endpoint = try? NanoleafEndpoint(host: host, port: sender.port) else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let model = txt["md"].flatMap { String(data: $0, encoding: .utf8) }
        guard model == nil || model?.uppercased() == "NL42" else { return }
        let id = txt["id"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        candidates[id] = NanoleafCandidate(id: id, name: sender.name, endpoint: endpoint, model: model)
        for serial in Array(pairings.keys) {
            guard var pairing = pairings[serial],
                  pairing.serviceID == id || pairing.endpoint == endpoint else { continue }
            pairing.endpoint = endpoint
            pairing.serviceID = id
            pairings[serial] = pairing
            do { try credentials.save(Array(pairings.values)) }
            catch { onDiscoveryError?(NanoleafError.storageFailure.localizedDescription) }
            refresh(serial)
        }
        publishCandidates()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard !paused, browser === self.browser else { return }
        onDiscoveryError?("Nanoleaf discovery could not start. Allow Local Network access, or pair using the controller’s IP address.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.removeAll { $0 == service }
        candidates = candidates.filter { $0.value.name != service.name }
        publishCandidates()
    }
}
