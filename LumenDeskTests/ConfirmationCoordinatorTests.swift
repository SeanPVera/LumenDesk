import XCTest
@testable import LumenDesk

final class ConfirmationCoordinatorTests: XCTestCase {
    @MainActor
    func testBalancedPolicyImmediatelyPerformsEligibleAction() {
        let coordinator = ConfirmationCoordinator { .balanced }
        var executionCount = 0

        coordinator.request(standardMetadata) { executionCount += 1 }

        XCTAssertEqual(executionCount, 1)
        XCTAssertNil(coordinator.pendingRequest)
    }

    @MainActor
    func testCautiousPolicyCreatesPendingRequestWithMetadata() throws {
        let coordinator = ConfirmationCoordinator { .cautious }
        var executed = false
        let metadata = ConfirmationCoordinator.ActionMetadata(
            title: "Delete Room?",
            message: "The room can be restored with Undo.",
            confirmTitle: "Delete Room",
            role: .destructive
        )

        coordinator.request(metadata) { executed = true }

        let request = try XCTUnwrap(coordinator.pendingRequest)
        XCTAssertEqual(request.metadata, metadata)
        XCTAssertEqual(request.title, "Delete Room?")
        XCTAssertEqual(request.confirmTitle, "Delete Room")
        XCTAssertTrue(request.isDestructive)
        XCTAssertFalse(executed)
    }

    @MainActor
    func testAlwaysConfirmRequestsUnderEveryPolicy() {
        for policy in ConfirmationPolicy.allCases {
            let coordinator = ConfirmationCoordinator { policy }
            var executed = false
            let metadata = ConfirmationCoordinator.ActionMetadata(
                title: "Import?",
                message: "This replaces the current configuration.",
                confirmTitle: "Import Configuration",
                role: .destructive,
                requirement: .always
            )

            coordinator.request(metadata) { executed = true }

            XCTAssertNotNil(coordinator.pendingRequest, "Expected a request under \(policy.title)")
            XCTAssertFalse(executed)
        }
    }

    @MainActor
    func testCancellingDoesNotExecuteAction() {
        let coordinator = ConfirmationCoordinator { .cautious }
        var executionCount = 0
        coordinator.request(standardMetadata) { executionCount += 1 }

        coordinator.cancelPendingRequest()
        coordinator.confirmPendingRequest()

        XCTAssertEqual(executionCount, 0)
        XCTAssertNil(coordinator.pendingRequest)
    }

    @MainActor
    func testConfirmingExecutesActionExactlyOnce() {
        let coordinator = ConfirmationCoordinator { .cautious }
        var executionCount = 0
        coordinator.request(standardMetadata) { executionCount += 1 }

        coordinator.confirmPendingRequest()
        coordinator.confirmPendingRequest()

        XCTAssertEqual(executionCount, 1)
        XCTAssertNil(coordinator.pendingRequest)
    }

    @MainActor
    func testReplacingAndDismissingPendingRequestsIsDeterministic() throws {
        let coordinator = ConfirmationCoordinator { .cautious }
        var firstExecutionCount = 0
        var secondExecutionCount = 0

        coordinator.request(standardMetadata) { firstExecutionCount += 1 }
        let firstID = try XCTUnwrap(coordinator.pendingRequest?.id)
        coordinator.request(
            .init(title: "Second", message: "Second action", confirmTitle: "Continue")
        ) { secondExecutionCount += 1 }

        XCTAssertNotEqual(coordinator.pendingRequest?.id, firstID)
        XCTAssertEqual(coordinator.pendingRequest?.title, "Second")

        coordinator.dismissPendingRequest()
        coordinator.confirmPendingRequest()

        XCTAssertNil(coordinator.pendingRequest)
        XCTAssertEqual(firstExecutionCount, 0)
        XCTAssertEqual(secondExecutionCount, 0)
    }

    private var standardMetadata: ConfirmationCoordinator.ActionMetadata {
        .init(
            title: "Apply Scene?",
            message: "This change can be undone.",
            confirmTitle: "Apply Scene"
        )
    }
}
