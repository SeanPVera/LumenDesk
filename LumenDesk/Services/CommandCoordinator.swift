import Foundation

enum DeviceCommandPhase: String, Codable {
    case idle, queued, sending, applied, failed

    var title: String {
        switch self {
        case .idle: return "Confirmed"
        case .queued: return "Queued"
        case .sending: return "Sending"
        case .applied: return "Applied"
        case .failed: return "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "checkmark.circle"
        case .queued: return "clock"
        case .sending: return "arrow.up.circle"
        case .applied: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

enum CommandLifecyclePhase: Equatable {
    case queued
    case sending
    case applied
    case confirmed
    case failed
    case timedOut
    case cancelled
    case sent

    var displayPhase: DeviceCommandPhase {
        switch self {
        case .queued: return .queued
        case .sending: return .sending
        case .applied: return .applied
        case .confirmed, .cancelled, .sent: return .idle
        case .failed, .timedOut: return .failed
        }
    }
}

struct DeviceCommandState: Equatable {
    var lifecycle: CommandLifecyclePhase
    var summary: String
    var updatedAt: Date
    var retryCount: Int

    var phase: DeviceCommandPhase { lifecycle.displayPhase }

    init(
        lifecycle: CommandLifecyclePhase = .confirmed,
        summary: String = "Confirmed",
        updatedAt: Date = Date(),
        retryCount: Int = 0
    ) {
        self.lifecycle = lifecycle
        self.summary = summary
        self.updatedAt = updatedAt
        self.retryCount = retryCount
    }
}

struct ConfirmedDeviceState: Equatable {
    var isOn: Bool
    var brightness: Double
    var colorHex: String
    var kelvin: Int
    var confirmedAt: Date
}

struct ExpectedDeviceState: Equatable {
    struct Color: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    var isOn: Bool?
    var brightness: Double?
    var color: Color?
    var kelvin: Int?
}

struct ReportedDeviceState {
    var isOn: Bool
    var brightness: Double
    var red: Double
    var green: Double
    var blue: Double
    var kelvin: Int
}

/// Owns the vendor-neutral lifecycle of lighting commands. Vendor clients
/// still encode packets and perform transport; this coordinator tracks the
/// command from queueing through confirmation, failure, timeout, or cancel.
@MainActor
final class CommandCoordinator {
    struct State: Equatable {
        var pendingDeviceIDs: Set<String> = []
        var commandStates: [String: DeviceCommandState] = [:]
        var confirmedStates: [String: ConfirmedDeviceState] = [:]
        var expectedStates: [String: ExpectedDeviceState] = [:]
    }

    struct Timing {
        var defaultDebounceNanoseconds: UInt64 = 80_000_000
        var confirmationRefreshNanoseconds: UInt64 = 1_200_000_000
        var commandTimeoutNanoseconds: UInt64 = 3_500_000_000
        var appliedDisplayNanoseconds: UInt64 = 1_200_000_000
        var simulatedResultNanoseconds: UInt64 = 450_000_000
        var unconfirmedAppliedNanoseconds: UInt64 = 900_000_000

        static let production = Timing()
    }

    struct SimulatedCommand {
        let isStale: @MainActor () -> Bool
        let didFail: @MainActor () -> Void
    }

    typealias Sleep = @Sendable (UInt64) async throws -> Void

    var onChange: (() -> Void)?

    private(set) var state: State
    private let timing: Timing
    private let now: () -> Date
    private let sleep: Sleep
    private var commandTasks: [String: Task<Void, Never>] = [:]
    private var commandTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var confirmationRefreshTasks: [String: Task<Void, Never>] = [:]
    private var settlingTasks: [String: Task<Void, Never>] = [:]

    init(
        state: State = State(),
        timing: Timing = .production,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.state = state
        self.timing = timing
        self.now = now
        self.sleep = sleep
    }

    var pendingDeviceIDs: Set<String> { state.pendingDeviceIDs }
    var commandStates: [String: DeviceCommandState] { state.commandStates }
    var confirmedStates: [String: ConfirmedDeviceState] { state.confirmedStates }

    func commandState(for deviceID: String) -> DeviceCommandState {
        state.commandStates[deviceID] ?? DeviceCommandState()
    }

    func markQueued(_ deviceID: String, summary: String = "Applying change") {
        updateState {
            state.pendingDeviceIDs.insert(deviceID)
            state.commandStates[deviceID] = DeviceCommandState(
                lifecycle: .queued,
                summary: summary,
                updatedAt: now()
            )
        }
    }

    func expectPower(deviceID: String, isOn: Bool) {
        updateState {
            state.expectedStates[deviceID, default: ExpectedDeviceState()].isOn = isOn
        }
    }

    func expectBrightness(deviceID: String, brightness: Double) {
        updateState {
            state.expectedStates[deviceID, default: ExpectedDeviceState()].brightness = max(0, min(1, brightness))
        }
    }

    func expectColor(deviceID: String, red: Double, green: Double, blue: Double) {
        updateState {
            state.expectedStates[deviceID, default: ExpectedDeviceState()].color = .init(
                red: red,
                green: green,
                blue: blue
            )
            state.expectedStates[deviceID]?.kelvin = nil
        }
    }

    func expectKelvin(deviceID: String, kelvin: Int) {
        updateState {
            state.expectedStates[deviceID, default: ExpectedDeviceState()].kelvin = kelvin
            state.expectedStates[deviceID]?.color = nil
        }
    }

    func reportedStateMatchesExpectation(deviceID: String, reported: ReportedDeviceState) -> Bool {
        guard let expected = state.expectedStates[deviceID] else { return false }
        if let value = expected.isOn, value != reported.isOn { return false }
        if let value = expected.brightness, abs(value - reported.brightness) > 0.03 { return false }
        if let value = expected.kelvin, abs(value - reported.kelvin) > 100 { return false }
        if let value = expected.color {
            let distance = max(
                abs(value.red - reported.red),
                max(abs(value.green - reported.green), abs(value.blue - reported.blue))
            )
            if distance > 0.06 { return false }
        }
        return true
    }

    func enqueue(
        deviceID: String,
        coalescingKey: String,
        summary: String,
        debounceNanoseconds: UInt64? = nil,
        simulated: SimulatedCommand? = nil,
        send: @escaping @MainActor () -> Void,
        refresh: @escaping @MainActor () -> Void,
        timedOut: @escaping @MainActor () -> Void
    ) {
        markQueued(deviceID, summary: summary)
        let taskKey = "\(deviceID)|\(coalescingKey)"
        commandTasks[taskKey]?.cancel()

        if let simulated {
            commandTasks[taskKey] = Task { @MainActor [weak self] in
                guard let self, await self.awaitDelay(self.timing.simulatedResultNanoseconds) else { return }
                let failed = simulated.isStale()
                self.updateState {
                    self.state.pendingDeviceIDs.remove(deviceID)
                    self.state.expectedStates.removeValue(forKey: deviceID)
                    self.state.commandStates[deviceID] = DeviceCommandState(
                        lifecycle: failed ? .failed : .applied,
                        summary: failed ? "Simulated timeout" : "Simulated: \(summary)",
                        updatedAt: self.now()
                    )
                }
                if failed { simulated.didFail() }
            }
            return
        }

        let delay = debounceNanoseconds ?? timing.defaultDebounceNanoseconds
        commandTasks[taskKey] = Task { @MainActor [weak self] in
            guard let self, await self.awaitDelay(delay) else { return }
            self.updateState {
                self.state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .sending,
                    summary: summary,
                    updatedAt: self.now(),
                    retryCount: self.state.commandStates[deviceID]?.retryCount ?? 0
                )
            }
            send()
            self.startTimeout(deviceID: deviceID, summary: summary, timedOut: timedOut)
            self.scheduleConfirmationRefresh(deviceID: deviceID, refresh: refresh)
        }
    }

    func recordObservation(
        deviceID: String,
        confirmedState: ConfirmedDeviceState,
        confirmsPendingCommand: Bool
    ) {
        if confirmsPendingCommand {
            commandTimeoutTasks[deviceID]?.cancel()
            commandTimeoutTasks[deviceID] = nil
            confirmationRefreshTasks[deviceID]?.cancel()
            confirmationRefreshTasks[deviceID] = nil
        }

        guard confirmsPendingCommand || !state.pendingDeviceIDs.contains(deviceID) else { return }
        updateState {
            if confirmsPendingCommand {
                state.pendingDeviceIDs.remove(deviceID)
                state.expectedStates.removeValue(forKey: deviceID)
            }
            state.confirmedStates[deviceID] = confirmedState
            state.commandStates[deviceID] = DeviceCommandState(
                lifecycle: confirmsPendingCommand ? .applied : .confirmed,
                summary: confirmsPendingCommand ? "Confirmed by light" : "Confirmed",
                updatedAt: now(),
                retryCount: state.commandStates[deviceID]?.retryCount ?? 0
            )
        }

        guard confirmsPendingCommand else { return }
        settlingTasks[deviceID]?.cancel()
        settlingTasks[deviceID] = Task { @MainActor [weak self] in
            guard let self, await self.awaitDelay(self.timing.appliedDisplayNanoseconds),
                  self.state.commandStates[deviceID]?.phase == .applied else { return }
            self.updateState {
                self.state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .confirmed,
                    summary: "Confirmed",
                    updatedAt: self.now(),
                    retryCount: self.state.commandStates[deviceID]?.retryCount ?? 0
                )
            }
        }
    }

    func fail(deviceIDs: Set<String>, summary: String) {
        guard !deviceIDs.isEmpty else { return }
        for deviceID in deviceIDs {
            commandTimeoutTasks[deviceID]?.cancel()
            commandTimeoutTasks[deviceID] = nil
            confirmationRefreshTasks[deviceID]?.cancel()
            confirmationRefreshTasks[deviceID] = nil
        }
        updateState {
            for deviceID in deviceIDs {
                state.pendingDeviceIDs.remove(deviceID)
                state.expectedStates.removeValue(forKey: deviceID)
                state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .failed,
                    summary: summary,
                    updatedAt: now(),
                    retryCount: state.commandStates[deviceID]?.retryCount ?? 0
                )
            }
        }
    }

    @discardableResult
    func cancel(deviceIDs requestedIDs: Set<String>? = nil) -> Set<String> {
        let taskDeviceIDs = Set(commandTasks.keys.map { key in
            key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
        })
        let deviceIDs = requestedIDs ?? state.pendingDeviceIDs.union(taskDeviceIDs)
        guard !deviceIDs.isEmpty else { return [] }

        for deviceID in deviceIDs {
            cancelTasks(for: deviceID)
        }
        updateState {
            for deviceID in deviceIDs {
                state.pendingDeviceIDs.remove(deviceID)
                state.expectedStates.removeValue(forKey: deviceID)
                state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .cancelled,
                    summary: "Cancelled",
                    updatedAt: now(),
                    retryCount: state.commandStates[deviceID]?.retryCount ?? 0
                )
            }
        }
        return deviceIDs
    }

    func retry(
        deviceID: String,
        refresh: @escaping @MainActor () -> Void,
        timedOut: @escaping @MainActor () -> Void
    ) {
        refresh()
        updateState {
            state.commandStates[deviceID] = DeviceCommandState(
                lifecycle: .sending,
                summary: "Checking confirmed state",
                updatedAt: now(),
                retryCount: (state.commandStates[deviceID]?.retryCount ?? 0) + 1
            )
        }
        startTimeout(deviceID: deviceID, summary: "state refresh", timedOut: timedOut)
    }

    func recover(deviceID: String, refresh: @escaping @MainActor () -> Void) {
        markQueued(deviceID)
        refresh()
    }

    func recordUnconfirmedSend(deviceID: String, summary: String) {
        settlingTasks[deviceID]?.cancel()
        updateState {
            state.commandStates[deviceID] = DeviceCommandState(
                lifecycle: .sending,
                summary: summary,
                updatedAt: now(),
                retryCount: state.commandStates[deviceID]?.retryCount ?? 0
            )
        }
        settlingTasks[deviceID] = Task { @MainActor [weak self] in
            guard let self, await self.awaitDelay(self.timing.unconfirmedAppliedNanoseconds),
                  self.state.commandStates[deviceID]?.phase == .sending else { return }
            self.updateState {
                self.state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .applied,
                    summary: summary,
                    updatedAt: self.now(),
                    retryCount: self.state.commandStates[deviceID]?.retryCount ?? 0
                )
            }
            guard await self.awaitDelay(self.timing.appliedDisplayNanoseconds),
                  self.state.commandStates[deviceID]?.phase == .applied else { return }
            self.updateState {
                self.state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .sent,
                    summary: "Sent",
                    updatedAt: self.now(),
                    retryCount: self.state.commandStates[deviceID]?.retryCount ?? 0
                )
            }
        }
    }

    func resumePendingCommand(
        deviceID: String,
        refresh: @escaping @MainActor () -> Void,
        timedOut: @escaping @MainActor () -> Void
    ) {
        scheduleConfirmationRefresh(deviceID: deviceID, refresh: refresh)
        startTimeout(deviceID: deviceID, summary: "restored pending command", timedOut: timedOut)
    }

    func cancelAllTasks(clearPendingAndExpectations: Bool) {
        commandTasks.values.forEach { $0.cancel() }
        commandTimeoutTasks.values.forEach { $0.cancel() }
        confirmationRefreshTasks.values.forEach { $0.cancel() }
        settlingTasks.values.forEach { $0.cancel() }
        commandTasks = [:]
        commandTimeoutTasks = [:]
        confirmationRefreshTasks = [:]
        settlingTasks = [:]

        if clearPendingAndExpectations {
            updateState {
                state.pendingDeviceIDs = []
                state.expectedStates = [:]
            }
        }
    }

    func restore(_ restoredState: State) {
        cancelAllTasks(clearPendingAndExpectations: false)
        updateState { state = restoredState }
    }

    private func scheduleConfirmationRefresh(
        deviceID: String,
        refresh: @escaping @MainActor () -> Void
    ) {
        confirmationRefreshTasks[deviceID]?.cancel()
        confirmationRefreshTasks[deviceID] = Task { @MainActor [weak self] in
            guard let self, await self.awaitDelay(self.timing.confirmationRefreshNanoseconds) else { return }
            refresh()
        }
    }

    private func startTimeout(
        deviceID: String,
        summary: String,
        timedOut: @escaping @MainActor () -> Void
    ) {
        commandTimeoutTasks[deviceID]?.cancel()
        commandTimeoutTasks[deviceID] = Task { @MainActor [weak self] in
            guard let self, await self.awaitDelay(self.timing.commandTimeoutNanoseconds),
                  self.state.commandStates[deviceID]?.phase == .sending else { return }
            self.updateState {
                self.state.pendingDeviceIDs.remove(deviceID)
                self.state.expectedStates.removeValue(forKey: deviceID)
                self.state.commandStates[deviceID] = DeviceCommandState(
                    lifecycle: .timedOut,
                    summary: "No confirmation: \(summary)",
                    updatedAt: self.now(),
                    retryCount: (self.state.commandStates[deviceID]?.retryCount ?? 0) + 1
                )
            }
            timedOut()
        }
    }

    private func cancelTasks(for deviceID: String) {
        for key in commandTasks.keys.filter({ $0.hasPrefix("\(deviceID)|") }) {
            commandTasks[key]?.cancel()
            commandTasks[key] = nil
        }
        commandTimeoutTasks[deviceID]?.cancel()
        commandTimeoutTasks[deviceID] = nil
        confirmationRefreshTasks[deviceID]?.cancel()
        confirmationRefreshTasks[deviceID] = nil
        settlingTasks[deviceID]?.cancel()
        settlingTasks[deviceID] = nil
    }

    private func awaitDelay(_ nanoseconds: UInt64) async -> Bool {
        guard nanoseconds > 0 else { return !Task.isCancelled }
        do {
            try await sleep(nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func updateState(_ mutation: () -> Void) {
        onChange?()
        mutation()
    }
}
