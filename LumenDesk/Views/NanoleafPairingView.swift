import SwiftUI

// MARK: - Pairing schedule

/// The timing of a Polar pairing attempt, kept pure so it can be tested.
///
/// 1. Hold: a 7-second countdown while the person holds the controller's
///    power button until its LED flashes. Nothing is sent.
/// 2. Listen: LumenDesk asks the controller for a token with the existing
///    pairing call (`LightManager.pairNanoleaf`, POST /api/v1/new). The
///    controller refuses (401/403, `.pairingWindowClosed`) until its pairing
///    window is open, so that one answer is retried every 3 seconds; any
///    other error fails at once.
/// 3. The whole attempt gives up 30 seconds after Start.
enum NanoleafPairingSchedule {
    static let holdSeconds = 7
    static let windowSeconds = 30
    static let retryInterval = 3

    static func shouldRetry(_ error: NanoleafError, elapsedSeconds: Int) -> Bool {
        error == .pairingWindowClosed && elapsedSeconds + retryInterval < windowSeconds
    }

    /// "0:04"
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum NanoleafPairingPhase: Equatable {
    case ready
    case holding(remaining: Int)
    case listening(elapsed: Int)
    case success(deviceID: String?)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .holding, .listening: return true
        default: return false
        }
    }
}

// MARK: - Pair Nanoleaf sheet

/// Polar "Pair Nanoleaf" sheet: 1 found on your network, 2 hold the power
/// button with a countdown, 3 room assignment, plus success, failure and
/// retry. Uses `LightManager.pairNanoleaf` unchanged.
struct NanoleafPairingView: View {
    @EnvironmentObject private var manager: LightManager
    @Environment(\.dismiss) private var dismiss

    /// Candidate chosen in Add lights, if any.
    var candidate: NanoleafCandidate? = nil
    /// Room offered first in step 3.
    var preferredRoomID: UUID? = nil
    /// Called with the new light's id after a successful pairing.
    var onPaired: ((String) -> Void)? = nil
    /// Starts in a given phase; used by the render review only.
    var initialPhase: NanoleafPairingPhase = .ready

    @State private var host: String = ""
    @State private var port: String = "16021"
    @State private var serviceID: String? = nil
    @State private var phase: NanoleafPairingPhase = .ready
    @State private var roomID: UUID? = nil
    @State private var attempt: Task<Void, Never>? = nil
    @State private var configured = false

    private var selectedCandidate: NanoleafCandidate? {
        manager.nanoleafCandidates.first { $0.id == serviceID } ?? (candidate?.id == serviceID ? candidate : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if manager.isDemoMode {
                        demoNote
                    }
                    stepFound
                    stepHold
                    resultCards
                    stepRoom
                }
                .padding(PolarSpacing.md)
            }
        }
        .frame(minWidth: 420, idealWidth: 520)
        .sheetFrame(minWidth: 420, idealWidth: 520, minHeight: 560, idealHeight: 640)
        .background(Polar.deck)
        .foregroundStyle(Polar.chalk)
        .interactiveDismissDisabled(phase.isBusy)
        .onAppear(perform: configure)
        .onDisappear { attempt?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            GlowingOrb(color: Polar.mint, level: 0.8, isOn: true, silhouette: .panels, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pair Nanoleaf")
                    .font(.polarDisplay(18, weight: .bold))
                Text(headerDetail)
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
                    .lineLimit(1)
            }
            Spacer()
            Button("Close") { close() }
                .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                .keyboardShortcut(.cancelAction)
        }
        .padding(PolarSpacing.md)
        .background(Polar.desk)
        .overlay(alignment: .bottom) { Rectangle().fill(Polar.ruleSoft).frame(height: 1) }
    }

    private var headerDetail: String {
        if let c = selectedCandidate {
            return [c.name, c.model.map { "\($0)" }, "mDNS"].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        return host.isEmpty ? "Shapes or Aurora on this network" : "\(host) \u{00B7} manual address"
    }

    private var demoNote: some View {
        Label("Sample Room is open. Leave it to pair a real controller; nothing is sent from here.",
              systemImage: "testtube.2")
            .font(.polarUI(12))
            .foregroundStyle(Polar.pending)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Polar.pending.opacity(0.10)))
    }

    // MARK: Step 1

    private var stepFound: some View {
        stepCard(number: 1, active: phase == .ready) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedCandidate == nil ? "Choose the controller" : "Found on your network")
                    .font(.polarUI(14, weight: .semibold))
                if let c = selectedCandidate {
                    Text("\(c.name)\(c.model.map { " (\($0))" } ?? "") \u{00B7} \(c.endpoint.host)")
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                }
                let others = manager.nanoleafCandidates.filter { $0.id != serviceID }
                if !others.isEmpty && !phase.isBusy {
                    ForEach(others) { item in
                        Button {
                            pick(item)
                        } label: {
                            HStack {
                                Image(systemName: "hexagon.fill").foregroundStyle(Polar.mint)
                                Text(item.name)
                                Text(item.endpoint.host).font(.polarMono(11)).foregroundStyle(Polar.meter)
                                Spacer()
                            }
                        }
                        .buttonStyle(PolarButtonStyle(kind: .quiet, compact: true))
                    }
                }
                if selectedCandidate == nil {
                    HStack(spacing: 8) {
                        TextField("IP address or local hostname", text: $host)
                        TextField("Port", text: $port).frame(width: 70)
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(phase.isBusy)
                    if manager.nanoleafCandidates.isEmpty {
                        Text(manager.nanoleafDiscoveryError ?? "Scanning for Shapes and Aurora controllers. You can also type the address from the Nanoleaf app or your router.")
                            .font(.polarUI(11))
                            .foregroundStyle(Polar.meter)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Step 2

    private var stepHold: some View {
        stepCard(number: 2, active: phase.isBusy) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hold the controller power button 5\u{2013}7 seconds")
                    .font(.polarUI(14, weight: .semibold))
                Text("The LED flashes when it enters pairing. Keep holding until the countdown finishes.")
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
                    .fixedSize(horizontal: false, vertical: true)
                switch phase {
                case .holding(let remaining):
                    countdown(clock: remaining, fraction: Double(NanoleafPairingSchedule.holdSeconds - remaining) / Double(NanoleafPairingSchedule.windowSeconds),
                              caption: "Hold the button\u{2026}")
                case .listening(let elapsed):
                    countdown(clock: NanoleafPairingSchedule.windowSeconds - elapsed,
                              fraction: Double(elapsed) / Double(NanoleafPairingSchedule.windowSeconds),
                              caption: "Listening for auth token\u{2026}")
                default:
                    Button {
                        start()
                    } label: {
                        Label("Start pairing", systemImage: "hexagon")
                    }
                    .buttonStyle(PolarButtonStyle(kind: .prominent))
                    .disabled(!canStart)
                }
            }
        }
    }

    private func countdown(clock: Int, fraction: Double, caption: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(NanoleafPairingSchedule.clock(clock))
                .font(.polarMono(26, weight: .bold))
                .foregroundStyle(Polar.accent)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Polar.raised)
                        Capsule()
                            .fill(LinearGradient(colors: [Polar.accent, Polar.mint], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
                .frame(height: 6)
                Text(caption)
                    .font(.polarUI(12))
                    .foregroundStyle(Polar.meter)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(clock) seconds left")
    }

    // MARK: Result

    @ViewBuilder
    private var resultCards: some View {
        switch phase {
        case .success:
            resultCard(title: "Success", tint: Polar.mint,
                       detail: "Paired \u{00B7} Confirmed\(roomName.map { " \u{00B7} Room: \($0)" } ?? "")") {
                Button {
                    close()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(PolarFilledButtonStyle(fill: Polar.mint))
            }
        case .failed(let message):
            resultCard(title: "Failed", tint: Polar.attention, detail: message) {
                Button {
                    start()
                } label: {
                    Text("Retry pairing").frame(maxWidth: .infinity)
                }
                .buttonStyle(PolarButtonStyle(kind: .quiet))
                .disabled(!canStart)
            }
        default:
            EmptyView()
        }
    }

    private func resultCard<Action: View>(title: String, tint: Color, detail: String,
                                          @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.polarUI(14, weight: .semibold))
                .foregroundStyle(tint)
            Text(detail)
                .font(.polarUI(12))
                .foregroundStyle(Polar.meter)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Polar.stage))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.4), lineWidth: 1))
    }

    // MARK: Step 3

    private var stepRoom: some View {
        stepCard(number: 3, active: { if case .success = phase { return true } else { return false } }()) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Room assignment")
                    .font(.polarUI(14, weight: .semibold))
                if manager.rooms.isEmpty {
                    Text("Create a room in Add lights; the wall waits unassigned until then.")
                        .font(.polarUI(12))
                        .foregroundStyle(Polar.meter)
                } else {
                    FlowChips(items: manager.rooms.map { ($0.id, $0.name) }, selected: roomID) { id in
                        roomID = id
                        if case .success(let deviceID?) = phase {
                            manager.assign(lightIDs: [deviceID], toRoom: id)
                        }
                    }
                }
            }
        }
    }

    private var roomName: String? { manager.rooms.first { $0.id == roomID }?.name }

    // MARK: Step card

    private func stepCard<Content: View>(number: Int, active: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.polarMono(12, weight: .bold))
                .foregroundStyle(active ? .white : Polar.meter)
                .frame(width: 24, height: 24)
                .background(Circle().fill(active ? Polar.accent : Polar.raised))
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? Polar.raised.opacity(0.7) : Polar.desk))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(active ? Polar.accent.opacity(0.7) : Polar.ruleSoft, lineWidth: 1))
    }

    // MARK: Actions

    private var canStart: Bool {
        !manager.isDemoMode && !phase.isBusy && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        if let candidate { pick(candidate) }
        roomID = preferredRoomID ?? manager.rooms.first?.id
        phase = initialPhase
        if !manager.isDemoMode { manager.scan() }
    }

    private func pick(_ item: NanoleafCandidate) {
        host = item.endpoint.host
        port = String(item.endpoint.port)
        serviceID = item.id
        if !phase.isBusy { phase = .ready }
    }

    private func close() {
        attempt?.cancel()
        attempt = nil
        dismiss()
    }

    private func start() {
        guard canStart else { return }
        guard let portNumber = Int(port) else {
            phase = .failed(NanoleafError.invalidAddress.localizedDescription)
            return
        }
        let targetHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = serviceID
        attempt?.cancel()
        attempt = Task { @MainActor in
            for remaining in stride(from: NanoleafPairingSchedule.holdSeconds, to: 0, by: -1) {
                phase = .holding(remaining: remaining)
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            var elapsed = NanoleafPairingSchedule.holdSeconds
            while !Task.isCancelled {
                phase = .listening(elapsed: elapsed)
                do {
                    try await manager.pairNanoleaf(host: targetHost, port: portNumber, serviceID: service)
                    let device = manager.devices.first { $0.brand == .nanoleaf && $0.address == targetHost }
                    if let device {
                        if let roomID { manager.assign(lightIDs: [device.id], toRoom: roomID) }
                        onPaired?(device.id)
                    }
                    phase = .success(deviceID: device?.id)
                    return
                } catch {
                    let failure = error as? NanoleafError ?? .unavailable
                    guard NanoleafPairingSchedule.shouldRetry(failure, elapsedSeconds: elapsed) else {
                        phase = .failed(failure == .pairingWindowClosed
                                        ? "No token within \(NanoleafPairingSchedule.windowSeconds)s. Hold the button until the LED flashes and retry, or check Wi\u{2011}Fi."
                                        : failure.localizedDescription)
                        return
                    }
                    for _ in 0..<NanoleafPairingSchedule.retryInterval {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                        elapsed += 1
                        phase = .listening(elapsed: elapsed)
                    }
                }
            }
        }
    }
}

/// Wrapping row of selectable chips (rooms in pairing and Add lights).
struct FlowChips<ID: Hashable>: View {
    let items: [(ID, String)]
    let selected: ID?
    let choose: (ID) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let isChosen = selected == item.0
                Button(item.1) { choose(item.0) }
                    .buttonStyle(PolarButtonStyle(kind: isChosen ? .selected : .quiet, compact: true))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
    }
}

/// A solid, full-width action in a custom colour (the mint Done).
struct PolarFilledButtonStyle: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.polarUI(13, weight: .semibold))
            .foregroundStyle(Polar.stage)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fill.opacity(configuration.isPressed ? 0.8 : 1)))
    }
}
