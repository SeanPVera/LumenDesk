import Foundation
import Darwin

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

/// Which kind of request failed, so the manager can tell an orientation
/// rejection from a colour write that did not land.
enum NanoleafOperation: String, Equatable {
    case state, effect, orientation, panelDisplay, identify, streamActivation, library, save
}

/// How LumenDesk's live stream to a controller stands. "Streaming" means
/// datagrams are leaving this machine; UDP gives no receipt, so it never
/// means the panels were seen to change.
enum NanoleafStreamStatus: Equatable {
    case idle
    case activating(owner: String)
    case streaming(owner: String)
    case failed(owner: String, NanoleafError)

    var owner: String? {
        switch self {
        case .idle: return nil
        case .activating(let owner), .streaming(let owner), .failed(let owner, _): return owner
        }
    }
}

/// Aggregate counters for one stream: submission, coalescing and local send
/// results only. Nothing here is evidence of what the panels displayed.
struct NanoleafStreamMetrics: Equatable {
    var framesSubmitted = 0
    var framesCoalesced = 0
    var datagramsSent = 0
    var sendFailures = 0
}

protocol NanoleafDatagramSending: AnyObject {
    func send(_ data: Data, to host: String, port: UInt16) throws
}

protocol NanoleafHostResolving {
    /// An IPv4 literal for the host, or nil. External control is UDP to the
    /// controller's own address, and LumenDesk's sockets are IPv4.
    func ipv4Address(for host: String) async -> String?
}

/// UDP out through the same BSD-socket wrapper the LIFX and Govee clients use.
final class NanoleafUDPSender: NanoleafDatagramSending {
    private let queue = DispatchQueue(label: "LumenDesk.nanoleafStream")
    private var socket: UDPSocket?

    func send(_ data: Data, to host: String, port: UInt16) throws {
        if socket == nil { socket = try UDPSocket(queue: queue) }
        try socket?.send(data, to: host, port: port)
    }
}

struct NanoleafSystemResolver: NanoleafHostResolving {
    func ipv4Address(for host: String) async -> String? {
        var probe = in_addr()
        if inet_pton(AF_INET, host, &probe) == 1 { return host }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(result) }
                var address: String?
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor, address == nil {
                    if entry.pointee.ai_family == AF_INET, let raw = entry.pointee.ai_addr {
                        var ipv4 = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                            address = String(cString: buffer)
                        }
                    }
                    cursor = entry.pointee.ai_next
                }
                continuation.resume(returning: address)
            }
        }
    }
}

@MainActor
final class NanoleafClient: NSObject {
    var onCandidates: (([NanoleafCandidate]) -> Void)?
    var onUpdate: ((NanoleafPairing, NanoleafInfo) -> Void)?
    var onFailure: ((String, NanoleafError) -> Void)?
    /// Same failures as `onFailure`, with the request that failed.
    var onOperationFailure: ((String, NanoleafOperation, NanoleafError) -> Void)?
    var onDiscoveryError: ((String) -> Void)?
    /// A write the controller answered with success. For orientation this
    /// is what makes the reading that follows authoritative.
    var onWriteAccepted: ((String, NanoleafOperation) -> Void)?
    /// Changes the controller announced on its event stream.
    var onEvent: ((String, NanoleafEvent) -> Void)?
    var onStreamStatus: ((String, NanoleafStreamStatus) -> Void)?

    private let credentials: NanoleafCredentialStoring
    private let session: URLSession
    private let eventSession: URLSession?
    private let datagrams: NanoleafDatagramSending
    private let resolver: NanoleafHostResolving
    private let streamPort: UInt16
    private let uptime: () -> TimeInterval
    private var pairings: [String: NanoleafPairing] = [:]
    private var candidates: [String: NanoleafCandidate] = [:]
    private var services: [NetService] = []
    private var browser: NetServiceBrowser?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pending: [String: Pending] = [:]
    private var operations: [String: [Operation]] = [:]
    private var streams: [String: StreamSession] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var generation = 0
    private var paused = false
    private var pairingInProgress = false
    private var didLoadCredentials = false

    /// A single in-flight request per controller with one coalesced successor.
    /// Slow HTTP controllers cannot accumulate hundreds of stale frames: a
    /// newer colour, effect or panel layout replaces a queued older one.
    private struct Pending {
        enum Output {
            case effect(String)
            case panels([NanoleafPanelFrame])
        }
        var state: [String: Any] = [:]
        /// What the wall should show next. An effect and a panel display are
        /// mutually exclusive, so only the most recent survives.
        var output: Output?
        var orientation: Int?
        var refresh = false

        var isEmpty: Bool { state.isEmpty && output == nil && orientation == nil && !refresh }
    }

    /// A one-shot request that needs its own result: reading the effect
    /// library, storing a design, identifying a panel, starting a stream.
    /// Runs in the controller's lane so it is ordered with everything else.
    private struct Operation {
        let kind: NanoleafOperation
        /// Fire-and-forget requests report failures through the callbacks;
        /// awaited ones hand them to their caller instead, except a revoked
        /// credential, which the manager always needs to hear about.
        let reportsFailures: Bool
        let run: @MainActor (NanoleafPairing) async throws -> Void
        let abandon: @MainActor (NanoleafError) -> Void
    }

    private final class StreamSession {
        let owner: String
        let token = UUID()
        var host: String?
        var status: NanoleafStreamStatus
        var pending: [Int: NanoleafPanelFrame] = [:]
        var lastSentAt = -Double.greatestFiniteMagnitude
        var flushTask: Task<Void, Never>?
        var metrics = NanoleafStreamMetrics()

        init(owner: String) {
            self.owner = owner
            status = .activating(owner: owner)
        }
    }

    init(credentials: NanoleafCredentialStoring = NanoleafCredentialStore(),
         session: URLSession? = nil,
         listensForEvents: Bool = true,
         datagrams: NanoleafDatagramSending = NanoleafUDPSender(),
         resolver: NanoleafHostResolving = NanoleafSystemResolver(),
         streamPort: UInt16 = NanoleafStreamPacket.defaultPort,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.credentials = credentials
        self.datagrams = datagrams
        self.resolver = resolver
        self.streamPort = streamPort
        self.uptime = uptime
        let delegate = NanoleafSessionDelegate()
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2
            configuration.timeoutIntervalForResource = 4
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
        if listensForEvents {
            // The event stream is one long-lived response, so it needs its own
            // session: the command session's two-second limits would cut it off.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            eventSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        } else {
            eventSession = nil
        }
        super.init()
    }

    // MARK: Discovery and pairing

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
        for serial in pairings.keys {
            refresh(serial)
            startEvents(serial)
        }
    }

    private func loadCredentials() throws {
        guard !didLoadCredentials else { return }
        for pairing in try credentials.load() { pairings[pairing.serial] = pairing }
        didLoadCredentials = true
    }

    /// Demo Mode also cancels queued HTTP traffic, live streams and event
    /// listeners, not just UI callbacks.
    func pause() {
        paused = true
        generation += 1
        browser?.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        pending.removeAll()
        let abandoned = operations.values.flatMap { $0 }
        operations.removeAll()
        abandoned.forEach { $0.abandon(.unavailable) }
        for serial in Array(streams.keys) { endStream(serial, notify: true) }
        eventTasks.values.forEach { $0.cancel() }
        eventTasks.removeAll()
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
        startEvents(info.serialNo)
    }

    func isPaired(_ serial: String) -> Bool { pairings[serial] != nil }

    /// Whether a write for this controller would be sent now, rather than
    /// dropped because the client is paused or the controller is unpaired.
    func canSend(_ serial: String) -> Bool { !paused && pairings[serial] != nil }

    // MARK: Coalesced writes

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
            next.output = nil
            endStream(serial, notify: true)
        } else if state["ct"] != nil {
            next.state.removeValue(forKey: "hue")
            next.state.removeValue(forKey: "sat")
            next.output = nil
            endStream(serial, notify: true)
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
        next.output = .effect(name)
        next.refresh = true
        pending[serial] = next
        endStream(serial, notify: true)
        drain(serial)
    }

    /// Shows a per-panel static layout without storing it as a scene. The
    /// newest request replaces any older one still queued, so painting
    /// quickly never builds a backlog.
    func displayPanels(_ serial: String, frames: [NanoleafPanelFrame], refresh: Bool = true) {
        guard !paused, pairings[serial] != nil else { return }
        var next = pending[serial] ?? Pending()
        next.state.removeValue(forKey: "hue")
        next.state.removeValue(forKey: "sat")
        next.state.removeValue(forKey: "ct")
        next.output = .panels(frames)
        next.refresh = next.refresh || refresh
        pending[serial] = next
        endStream(serial, notify: true)
        drain(serial)
    }

    /// Writes the global orientation. The controller answers 204 with no
    /// body, so a refresh always follows: success is what reads back.
    func setOrientation(_ serial: String, degrees: Int) {
        guard !paused, pairings[serial] != nil else { return }
        var next = pending[serial] ?? Pending()
        next.orientation = degrees
        next.refresh = true
        pending[serial] = next
        drain(serial)
    }

    // MARK: One-shot requests

    /// Every stored effect with its full definition (`requestAll`).
    func effectLibrary(_ serial: String) async throws -> [NanoleafEffectDefinition] {
        try await perform(serial, .library) { pairing in
            let data = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                              method: "PUT", body: NanoleafCommand.requestAll)
            do { return try NanoleafEffectDefinition.parseLibrary(data) }
            catch { throw NanoleafError.invalidResponse }
        }
    }

    /// The motions installed on the controller and their option ranges.
    func plugins(_ serial: String) async throws -> [NanoleafPluginDescription] {
        try await perform(serial, .library) { pairing in
            let data = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                              method: "PUT", body: NanoleafCommand.requestPlugins)
            do { return try NanoleafPluginDescription.parseList(data) }
            catch { throw NanoleafError.invalidResponse }
        }
    }

    /// Shows an edited effect temporarily without storing it.
    func previewEffect(_ serial: String, _ definition: NanoleafEffectDefinition) async throws {
        endStream(serial, notify: true)
        try await perform(serial, .effect) { pairing in
            _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                       method: "PUT", body: definition.writeBody(command: "display"))
            self.refresh(pairing.serial)
        }
    }

    /// Stores an effect definition under `name`. Refuses to replace an
    /// existing effect unless `allowOverwrite` is set, checked against a
    /// fresh read of the controller's list rather than a cached one.
    func saveEffect(_ serial: String, _ definition: NanoleafEffectDefinition, name: String,
                    allowOverwrite: Bool) async throws {
        let name = try Self.validatedEffectName(name)
        try await perform(serial, .save) { pairing in
            try await self.guardName(name, pairing: pairing, allowOverwrite: allowOverwrite)
            _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                       method: "PUT", body: definition.writeBody(command: "add", name: name))
            self.refresh(pairing.serial)
        }
    }

    /// Stores a static per-panel design on the controller and reads it back.
    /// Returns true when the stored animation data matches what was sent,
    /// which is as far as the API can confirm: storage, not display.
    @discardableResult
    func saveStaticDesign(_ serial: String, name: String, frames: [NanoleafPanelFrame],
                          allowOverwrite: Bool) async throws -> Bool {
        let name = try Self.validatedEffectName(name)
        return try await perform(serial, .save) { pairing in
            try await self.guardName(name, pairing: pairing, allowOverwrite: allowOverwrite)
            _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                       method: "PUT", body: NanoleafCommand.addStatic(name: name, frames: frames))
            let stored = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                                method: "PUT", body: NanoleafCommand.request(name))
            self.refresh(pairing.serial)
            guard let definition = try? NanoleafEffectDefinition.parseLibrary(stored).first,
                  let colors = definition.staticColors else { return false }
            let sent = Dictionary(frames.map { ($0.panelID, $0.rgb) }, uniquingKeysWith: { _, new in new })
            return colors == sent
        }
    }

    /// Breathes one panel for a few seconds with `displayTemp`, after which
    /// the controller restores what it was showing by itself.
    func identifyPanel(_ serial: String, panelID: Int, layout: NanoleafLayout) {
        guard layout.paintableIDs.contains(panelID) else { return }
        enqueue(serial, .identify) { pairing in
            _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                       method: "PUT", body: NanoleafCommand.identifyPanel(panelID, in: layout))
        }
    }

    /// Nanoleaf's own whole-controller identify: every panel flashes.
    func identifyController(_ serial: String) {
        enqueue(serial, .identify) { pairing in
            _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/identify",
                                       method: "PUT")
        }
    }

    static func validatedEffectName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Names wrapped in asterisks are reserved for the controller's own
        // modes (*Static*, *Dynamic*, *Solid*).
        guard !trimmed.isEmpty, trimmed.count <= 64, !(trimmed.hasPrefix("*") && trimmed.hasSuffix("*")) else {
            throw NanoleafError.invalidName
        }
        return trimmed
    }

    private func guardName(_ name: String, pairing: NanoleafPairing, allowOverwrite: Bool) async throws {
        guard !allowOverwrite else { return }
        let info = try await readInfo(endpoint: pairing.endpoint, token: pairing.token)
        if info.effects.effectsList.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw NanoleafError.nameConflict
        }
    }

    private func enqueue(_ serial: String, _ kind: NanoleafOperation,
                         _ work: @escaping @MainActor (NanoleafPairing) async throws -> Void) {
        guard !paused, pairings[serial] != nil else { return }
        operations[serial, default: []].append(Operation(kind: kind, reportsFailures: true, run: work, abandon: { _ in }))
        drain(serial)
    }

    /// Whether anything is queued or in flight for a controller.
    func hasWork(_ serial: String) -> Bool {
        tasks[serial] != nil || !(pending[serial]?.isEmpty ?? true) || !(operations[serial]?.isEmpty ?? true)
    }

    private func perform<T>(_ serial: String, _ kind: NanoleafOperation,
                            _ work: @escaping @MainActor (NanoleafPairing) async throws -> T) async throws -> T {
        guard !paused, pairings[serial] != nil else { throw NanoleafError.unavailable }
        let enqueuedGeneration = generation
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let operation = Operation(kind: kind, reportsFailures: false, run: { pairing in
                do {
                    let value = try await work(pairing)
                    // A reply that lands after Demo Mode began belongs to a
                    // session that no longer exists.
                    guard self.generation == enqueuedGeneration else { throw NanoleafError.unavailable }
                    if !finished { finished = true; continuation.resume(returning: value) }
                } catch {
                    if !finished { finished = true; continuation.resume(throwing: error) }
                    throw error
                }
            }, abandon: { error in
                if !finished { finished = true; continuation.resume(throwing: error) }
            })
            operations[serial, default: []].append(operation)
            drain(serial)
        }
    }

    // MARK: The per-controller lane

    private func drain(_ serial: String) {
        guard tasks[serial] == nil, !paused else { return }
        let generation = self.generation
        tasks[serial] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == self.generation { self.tasks.removeValue(forKey: serial) } }
            while !Task.isCancelled, generation == self.generation, let pairing = self.pairings[serial] {
                let command = self.pending.removeValue(forKey: serial)
                let operation = self.operations[serial]?.isEmpty == false ? self.operations[serial]?.removeFirst() : nil
                if command == nil && operation == nil { break }
                if let command { await self.run(command, pairing: pairing, generation: generation) }
                if let operation {
                    guard generation == self.generation, !Task.isCancelled else {
                        operation.abandon(.unavailable)
                        return
                    }
                    do {
                        try await operation.run(pairing)
                    } catch {
                        guard generation == self.generation, !Task.isCancelled else { return }
                        let failure = error as? NanoleafError ?? .unavailable
                        if failure == .pairingRequired { self.pending.removeValue(forKey: serial) }
                        if operation.reportsFailures || failure == .pairingRequired {
                            self.report(serial, operation.kind, failure)
                        }
                    }
                }
            }
        }
    }

    private func run(_ command: Pending, pairing: NanoleafPairing, generation: Int) async {
        let serial = pairing.serial
        var kind = NanoleafOperation.state
        do {
            if !command.state.isEmpty {
                kind = .state
                _ = try await request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/state",
                                      method: "PUT", body: command.state)
            }
            switch command.output {
            case .effect(let effect):
                kind = .effect
                try Task.checkCancellation()
                _ = try await request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                      method: "PUT", body: NanoleafCommand.select(effect))
                onWriteAccepted?(serial, .effect)
            case .panels(let frames):
                kind = .panelDisplay
                try Task.checkCancellation()
                _ = try await request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                      method: "PUT", body: NanoleafCommand.displayStatic(frames))
                onWriteAccepted?(serial, .panelDisplay)
            case nil:
                break
            }
            if let orientation = command.orientation {
                kind = .orientation
                try Task.checkCancellation()
                _ = try await request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/panelLayout",
                                      method: "PUT", body: NanoleafCommand.orientation(orientation))
                onWriteAccepted?(serial, .orientation)
            }
            if command.refresh {
                kind = .state
                let info = try await readInfo(endpoint: pairing.endpoint, token: pairing.token)
                guard generation == self.generation, !Task.isCancelled else { return }
                guard info.serialNo == serial, info.isShapes else { throw NanoleafError.invalidResponse }
                onUpdate?(pairing, info)
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            let failure = error as? NanoleafError ?? .unavailable
            if failure == .pairingRequired { pending.removeValue(forKey: serial) }
            report(serial, kind, failure)
        }
    }

    private func report(_ serial: String, _ kind: NanoleafOperation, _ failure: NanoleafError) {
        if failure == .pairingRequired {
            endStream(serial, notify: true)
            eventTasks.removeValue(forKey: serial)?.cancel()
        }
        onOperationFailure?(serial, kind, failure)
        onFailure?(serial, failure)
    }

    // MARK: External control stream

    func streamStatus(_ serial: String) -> NanoleafStreamStatus {
        streams[serial]?.status ?? .idle
    }

    func streamMetrics(_ serial: String) -> NanoleafStreamMetrics? {
        streams[serial]?.metrics
    }

    /// Puts the controller into external control and claims its output for
    /// `owner`. A later start by another owner replaces this one, and any
    /// effect, colour or panel command ends it, so a stale stream can never
    /// outlive the action that superseded it.
    func startStream(_ serial: String, owner: String) {
        guard !paused, pairings[serial] != nil else { return }
        if let existing = streams[serial], existing.owner == owner {
            if case .failed = existing.status {} else { return }
        }
        endStream(serial, notify: false)
        let session = StreamSession(owner: owner)
        streams[serial] = session
        onStreamStatus?(serial, session.status)
        let token = session.token
        enqueue(serial, .streamActivation) { pairing in
            guard self.streams[serial]?.token == token else { return }
            do {
                guard let host = await self.resolver.ipv4Address(for: pairing.endpoint.host) else {
                    throw NanoleafError.streamUnavailable
                }
                guard self.streams[serial]?.token == token else { return }
                _ = try await self.request(endpoint: pairing.endpoint, path: "/api/v1/\(pairing.token)/effects",
                                           method: "PUT", body: NanoleafCommand.externalControl)
                guard let live = self.streams[serial], live.token == token else { return }
                live.host = host
                live.status = .streaming(owner: owner)
                self.onStreamStatus?(serial, live.status)
                self.flush(serial, token: token)
            } catch {
                // Frames queued for a stream that never opened must not be
                // sent later to a controller that has moved on.
                if let live = self.streams[serial], live.token == token {
                    live.pending.removeAll()
                    live.status = .failed(owner: owner, error as? NanoleafError ?? .unavailable)
                    self.onStreamStatus?(serial, live.status)
                }
                throw error
            }
        }
    }

    /// Queues a frame for the owner's stream. Panels merge by ID, newest
    /// wins, and at most one datagram leaves per tenth of a second.
    func submitStreamFrame(_ serial: String, owner: String, frames: [NanoleafPanelFrame]) {
        guard !paused, let session = streams[serial], session.owner == owner else { return }
        switch session.status {
        case .failed, .idle: return
        default: break
        }
        session.metrics.framesSubmitted += 1
        if !session.pending.isEmpty { session.metrics.framesCoalesced += 1 }
        for frame in frames { session.pending[frame.panelID] = frame }
        flush(serial, token: session.token)
    }

    /// Ends a stream. With an owner, only that owner's stream ends, so a
    /// late stop from a finished show cannot cut off a newer one.
    func stopStream(_ serial: String, owner: String? = nil) {
        guard let session = streams[serial], owner == nil || session.owner == owner else { return }
        endStream(serial, notify: true)
    }

    private func endStream(_ serial: String, notify: Bool) {
        guard let session = streams.removeValue(forKey: serial) else { return }
        session.flushTask?.cancel()
        session.pending.removeAll()
        if notify { onStreamStatus?(serial, .idle) }
    }

    private func flush(_ serial: String, token: UUID) {
        guard let session = streams[serial], session.token == token,
              case .streaming = session.status, let host = session.host,
              !session.pending.isEmpty, session.flushTask == nil else { return }
        let wait = session.lastSentAt + NanoleafStreamPacket.minimumFrameInterval - uptime()
        if wait > 0 {
            session.flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, let live = self.streams[serial], live.token == token, !Task.isCancelled else { return }
                live.flushTask = nil
                self.flush(serial, token: token)
            }
            return
        }
        let frames = session.pending.values.sorted { $0.panelID < $1.panelID }
        session.pending.removeAll()
        session.lastSentAt = uptime()
        do {
            try datagrams.send(NanoleafStreamPacket.encode(frames), to: host, port: streamPort)
            session.metrics.datagramsSent += 1
        } catch {
            session.metrics.sendFailures += 1
        }
    }

    // MARK: Event stream

    private func startEvents(_ serial: String) {
        guard let eventSession, !paused, eventTasks[serial] == nil, pairings[serial] != nil else { return }
        let generation = self.generation
        eventTasks[serial] = Task { @MainActor [weak self] in
            var delay: UInt64 = 2_000_000_000
            while !Task.isCancelled {
                guard let self, generation == self.generation, let pairing = self.pairings[serial] else { return }
                var request: URLRequest
                do {
                    request = URLRequest(url: try pairing.endpoint.url(path: "/api/v1/\(pairing.token)/events"))
                } catch { return }
                var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "id", value: "1,2,3,4")]
                if let url = components?.url { request.url = url }
                request.cachePolicy = .reloadIgnoringLocalCacheData
                do {
                    let (bytes, response) = try await eventSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                        self.report(serial, .state, .pairingRequired)
                        return
                    }
                    delay = 2_000_000_000
                    var parser = NanoleafEventStreamParser()
                    for try await line in bytes.lines {
                        guard generation == self.generation, !Task.isCancelled else { return }
                        for event in parser.consume(line: line) { self.onEvent?(serial, event) }
                    }
                } catch {
                    // Dropped connection, sleep/wake, address change: retry below.
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 60_000_000_000)
            }
        }
    }

    // MARK: HTTP

    private func readInfo(endpoint: NanoleafEndpoint, token: String) async throws -> NanoleafInfo {
        let data = try await request(endpoint: endpoint, path: "/api/v1/\(token)", method: "GET")
        guard var info = try? JSONDecoder().decode(NanoleafInfo.self, from: data) else {
            throw NanoleafError.invalidResponse
        }
        info.topology = NanoleafTopologyParser.parse(data)
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
            let moved = pairing.endpoint != endpoint
            pairing.endpoint = endpoint
            pairing.serviceID = id
            pairings[serial] = pairing
            do { try credentials.save(Array(pairings.values)) }
            catch { onDiscoveryError?(NanoleafError.storageFailure.localizedDescription) }
            if moved {
                // A stream aimed at the old address would go nowhere; the
                // owner restarts it against the new one.
                endStream(serial, notify: true)
                eventTasks.removeValue(forKey: serial)?.cancel()
            }
            refresh(serial)
            startEvents(serial)
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
