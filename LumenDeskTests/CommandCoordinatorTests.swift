import XCTest
@testable import LumenDesk

final class CommandCoordinatorTests: XCTestCase {
    @MainActor
    func testCommandTransitionsFromQueuedToSendingToConfirmed() async {
        let coordinator = makeCoordinator()
        var sendCount = 0
        var refreshCount = 0

        coordinator.enqueue(
            deviceID: "light-1",
            coalescingKey: "power",
            summary: "Turning on",
            debounceNanoseconds: 0,
            send: { sendCount += 1 },
            refresh: { refreshCount += 1 },
            timedOut: { XCTFail("A confirmed command must not time out") }
        )

        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .queued)
        XCTAssertTrue(coordinator.pendingDeviceIDs.contains("light-1"))
        await waitUntil { coordinator.commandState(for: "light-1").phase == .sending }
        XCTAssertEqual(sendCount, 1)

        let confirmed = confirmedState(isOn: true)
        coordinator.recordObservation(
            deviceID: "light-1",
            confirmedState: confirmed,
            confirmsPendingCommand: true
        )

        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .applied)
        XCTAssertFalse(coordinator.pendingDeviceIDs.contains("light-1"))
        XCTAssertEqual(coordinator.confirmedStates["light-1"], confirmed)
        await waitUntil { coordinator.commandState(for: "light-1").phase == .idle }
        XCTAssertEqual(coordinator.commandState(for: "light-1").summary, "Confirmed")
        XCTAssertEqual(refreshCount, 0)
    }

    @MainActor
    func testTimeoutFailsCommandAndCleansExpectedState() async {
        let coordinator = makeCoordinator()
        var timeoutCount = 0
        coordinator.expectPower(deviceID: "light-1", isOn: true)
        coordinator.enqueue(
            deviceID: "light-1",
            coalescingKey: "power",
            summary: "Turning on",
            debounceNanoseconds: 0,
            send: {},
            refresh: {},
            timedOut: { timeoutCount += 1 }
        )

        await waitUntil { coordinator.commandState(for: "light-1").phase == .failed }

        XCTAssertEqual(timeoutCount, 1)
        XCTAssertEqual(coordinator.commandState(for: "light-1").lifecycle, .timedOut)
        XCTAssertEqual(coordinator.commandState(for: "light-1").summary, "No confirmation: Turning on")
        XCTAssertEqual(coordinator.commandState(for: "light-1").retryCount, 1)
        XCTAssertFalse(coordinator.pendingDeviceIDs.contains("light-1"))
        XCTAssertNil(coordinator.state.expectedStates["light-1"])
    }

    @MainActor
    func testLateConfirmationAfterTimeoutIsAccepted() async {
        let coordinator = makeCoordinator()
        coordinator.enqueue(
            deviceID: "light-1",
            coalescingKey: "brightness",
            summary: "Brightness 40 percent",
            debounceNanoseconds: 0,
            send: {},
            refresh: {},
            timedOut: {}
        )
        await waitUntil { coordinator.commandState(for: "light-1").phase == .failed }

        let lateState = confirmedState(isOn: true, brightness: 0.4)
        coordinator.recordObservation(
            deviceID: "light-1",
            confirmedState: lateState,
            confirmsPendingCommand: false
        )

        XCTAssertEqual(coordinator.commandState(for: "light-1").lifecycle, .confirmed)
        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .idle)
        XCTAssertEqual(coordinator.confirmedStates["light-1"], lateState)
    }

    @MainActor
    func testFailureFollowedByRetryExecutesRefreshAndCanConfirm() async {
        let coordinator = makeCoordinator()
        coordinator.enqueue(
            deviceID: "light-1",
            coalescingKey: "color",
            summary: "Changing color",
            debounceNanoseconds: 0,
            send: {},
            refresh: {},
            timedOut: {}
        )
        await waitUntil { coordinator.commandState(for: "light-1").phase == .sending }
        coordinator.fail(deviceIDs: ["light-1"], summary: "Vendor rejected the command")
        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .failed)
        XCTAssertEqual(coordinator.commandState(for: "light-1").lifecycle, .failed)

        var refreshCount = 0
        coordinator.retry(
            deviceID: "light-1",
            refresh: { refreshCount += 1 },
            timedOut: { XCTFail("The retry was confirmed") }
        )

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .sending)
        XCTAssertEqual(coordinator.commandState(for: "light-1").retryCount, 1)
        coordinator.recordObservation(
            deviceID: "light-1",
            confirmedState: confirmedState(isOn: true),
            confirmsPendingCommand: true
        )
        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .applied)
    }

    @MainActor
    func testCancellationPreventsQueuedSendAndCleansExpectation() async {
        let coordinator = makeCoordinator()
        var sendCount = 0
        coordinator.expectBrightness(deviceID: "light-1", brightness: 0.8)
        coordinator.enqueue(
            deviceID: "light-1",
            coalescingKey: "brightness",
            summary: "Brightness 80 percent",
            debounceNanoseconds: 40_000_000,
            send: { sendCount += 1 },
            refresh: {},
            timedOut: {}
        )

        let cancelled = coordinator.cancel(deviceIDs: ["light-1"])
        XCTAssertEqual(cancelled, ["light-1"])
        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .idle)
        XCTAssertEqual(coordinator.commandState(for: "light-1").summary, "Cancelled")
        XCTAssertFalse(coordinator.pendingDeviceIDs.contains("light-1"))
        XCTAssertNil(coordinator.state.expectedStates["light-1"])

        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(sendCount, 0)
    }

    @MainActor
    func testCompletedCommandIsNotCancelledLater() async {
        let coordinator = makeCoordinator()
        coordinator.enqueue(
            deviceID: "light-1",
            coalescingKey: "power",
            summary: "Turning on",
            debounceNanoseconds: 0,
            send: {},
            refresh: {},
            timedOut: { XCTFail("The command was confirmed") }
        )

        await waitUntil { coordinator.commandState(for: "light-1").phase == .sending }
        coordinator.recordObservation(
            deviceID: "light-1",
            confirmedState: confirmedState(isOn: true),
            confirmsPendingCommand: true
        )
        await waitUntil { coordinator.commandState(for: "light-1").phase == .idle }

        XCTAssertTrue(coordinator.cancel().isEmpty)
        XCTAssertEqual(coordinator.commandState(for: "light-1").lifecycle, .confirmed)
    }

    @MainActor
    func testSupersededCommandWithSameKeySendsOnlyLatestOperation() async {
        let coordinator = makeCoordinator()
        var sentValues: [Int] = []
        for value in [20, 80] {
            coordinator.enqueue(
                deviceID: "light-1",
                coalescingKey: "brightness",
                summary: "Brightness \(value) percent",
                debounceNanoseconds: 25_000_000,
                send: { sentValues.append(value) },
                refresh: {},
                timedOut: {}
            )
        }

        await waitUntil { sentValues.count == 1 }
        XCTAssertEqual(sentValues, [80])
        XCTAssertEqual(coordinator.commandState(for: "light-1").summary, "Brightness 80 percent")
        coordinator.cancel(deviceIDs: ["light-1"])
    }

    @MainActor
    func testBroadCommandsTrackEveryDeviceIndependently() {
        let coordinator = makeCoordinator()
        for deviceID in ["light-1", "light-2", "light-3"] {
            coordinator.enqueue(
                deviceID: deviceID,
                coalescingKey: "power",
                summary: "Turning off",
                debounceNanoseconds: 100_000_000,
                send: {},
                refresh: {},
                timedOut: {}
            )
        }

        XCTAssertEqual(coordinator.pendingDeviceIDs, ["light-1", "light-2", "light-3"])
        XCTAssertTrue(coordinator.commandStates.values.allSatisfy { $0.phase == .queued })
        XCTAssertEqual(coordinator.cancel(), ["light-1", "light-2", "light-3"])
        XCTAssertTrue(coordinator.pendingDeviceIDs.isEmpty)
    }

    @MainActor
    func testExpectedStateMatchingUsesExistingProtocolTolerances() {
        let coordinator = makeCoordinator()
        coordinator.expectPower(deviceID: "light-1", isOn: true)
        coordinator.expectBrightness(deviceID: "light-1", brightness: 0.5)
        coordinator.expectColor(deviceID: "light-1", red: 0.8, green: 0.2, blue: 0.1)

        XCTAssertTrue(coordinator.reportedStateMatchesExpectation(
            deviceID: "light-1",
            reported: .init(isOn: true, brightness: 0.52, red: 0.75, green: 0.24, blue: 0.12, kelvin: 3_500)
        ))
        XCTAssertFalse(coordinator.reportedStateMatchesExpectation(
            deviceID: "light-1",
            reported: .init(isOn: true, brightness: 0.6, red: 0.8, green: 0.2, blue: 0.1, kelvin: 3_500)
        ))

        coordinator.expectKelvin(deviceID: "light-1", kelvin: 3_000)
        XCTAssertNil(coordinator.state.expectedStates["light-1"]?.color)
        XCTAssertTrue(coordinator.reportedStateMatchesExpectation(
            deviceID: "light-1",
            reported: .init(isOn: true, brightness: 0.5, red: 1, green: 1, blue: 1, kelvin: 3_100)
        ))
    }

    @MainActor
    func testSimulatedCommandsNeverSendToTransport() async {
        let coordinator = makeCoordinator()
        var sendCount = 0
        var failureCount = 0
        coordinator.enqueue(
            deviceID: "demo:1",
            coalescingKey: "power",
            summary: "Turning on",
            simulated: .init(isStale: { false }, didFail: { failureCount += 1 }),
            send: { sendCount += 1 },
            refresh: {},
            timedOut: {}
        )
        await waitUntil { coordinator.commandState(for: "demo:1").phase == .applied }

        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(failureCount, 0)
        XCTAssertFalse(coordinator.pendingDeviceIDs.contains("demo:1"))

        coordinator.enqueue(
            deviceID: "demo:2",
            coalescingKey: "power",
            summary: "Turning off",
            simulated: .init(isStale: { true }, didFail: { failureCount += 1 }),
            send: { sendCount += 1 },
            refresh: {},
            timedOut: {}
        )
        await waitUntil { coordinator.commandState(for: "demo:2").phase == .failed }
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(failureCount, 1)
    }

    @MainActor
    func testUnconfirmedSegmentSendAndRecoveryActionsAreCoordinated() async {
        let coordinator = makeCoordinator()
        coordinator.recordUnconfirmedSend(deviceID: "light-1", summary: "Applying layout")
        XCTAssertEqual(coordinator.commandState(for: "light-1").phase, .sending)
        await waitUntil { coordinator.commandState(for: "light-1").phase == .applied }
        await waitUntil { coordinator.commandState(for: "light-1").phase == .idle }
        XCTAssertEqual(coordinator.commandState(for: "light-1").summary, "Sent")

        var refreshCount = 0
        coordinator.recover(deviceID: "light-2") { refreshCount += 1 }
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(coordinator.pendingDeviceIDs.contains("light-2"))
        XCTAssertEqual(coordinator.commandState(for: "light-2").phase, .queued)
    }

    @MainActor
    func testStateSnapshotRestoresPendingAndExpectedStateAfterWorkspaceTransition() {
        let coordinator = makeCoordinator()
        coordinator.expectPower(deviceID: "light-1", isOn: true)
        coordinator.markQueued("light-1", summary: "Turning on")
        coordinator.recordObservation(
            deviceID: "light-2",
            confirmedState: confirmedState(isOn: false),
            confirmsPendingCommand: false
        )
        let liveState = coordinator.state

        coordinator.cancelAllTasks(clearPendingAndExpectations: true)
        XCTAssertTrue(coordinator.pendingDeviceIDs.isEmpty)
        XCTAssertTrue(coordinator.state.expectedStates.isEmpty)

        coordinator.restore(liveState)
        XCTAssertEqual(coordinator.state, liveState)
    }

    @MainActor
    private func makeCoordinator() -> CommandCoordinator {
        CommandCoordinator(timing: .init(
            defaultDebounceNanoseconds: 2_000_000,
            confirmationRefreshNanoseconds: 15_000_000,
            commandTimeoutNanoseconds: 45_000_000,
            appliedDisplayNanoseconds: 8_000_000,
            simulatedResultNanoseconds: 2_000_000,
            unconfirmedAppliedNanoseconds: 2_000_000
        ))
    }

    private func confirmedState(
        isOn: Bool,
        brightness: Double = 1
    ) -> ConfirmedDeviceState {
        ConfirmedDeviceState(
            isOn: isOn,
            brightness: brightness,
            colorHex: "#FFFFFF",
            kelvin: 3_500,
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        attempts: Int = 500
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for command lifecycle transition")
    }
}
