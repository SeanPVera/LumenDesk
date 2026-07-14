import Combine
import Foundation

/// Owns the confirmation policy and pending-request lifecycle for managed
/// application actions. Callers supply action-specific copy and work; this
/// coordinator decides whether the work runs immediately or waits for the UI.
@MainActor
final class ConfirmationCoordinator: ObservableObject {
    struct ActionMetadata: Equatable {
        enum Role: Equatable {
            case standard
            case destructive
        }

        enum Requirement: Equatable {
            case policy
            case always
        }

        let title: String
        let message: String
        let confirmTitle: String
        let role: Role
        let requirement: Requirement

        init(
            title: String,
            message: String,
            confirmTitle: String,
            role: Role = .standard,
            requirement: Requirement = .policy
        ) {
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
            self.role = role
            self.requirement = requirement
        }

        var isDestructive: Bool { role == .destructive }
    }

    struct PendingRequest: Identifiable {
        let id: UUID
        let metadata: ActionMetadata
        fileprivate let action: @MainActor () -> Void

        fileprivate init(
            id: UUID = UUID(),
            metadata: ActionMetadata,
            action: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.metadata = metadata
            self.action = action
        }

        var title: String { metadata.title }
        var message: String { metadata.message }
        var confirmTitle: String { metadata.confirmTitle }
        var isDestructive: Bool { metadata.isDestructive }
    }

    @Published private(set) var pendingRequest: PendingRequest?

    private let policyProvider: () -> ConfirmationPolicy

    init(policyProvider: @escaping () -> ConfirmationPolicy) {
        self.policyProvider = policyProvider
    }

    convenience init(defaults: UserDefaults) {
        self.init {
            guard let rawValue = defaults.string(forKey: AppPreferenceKey.confirmationPolicy) else {
                return .balanced
            }
            return ConfirmationPolicy(rawValue: rawValue) ?? .balanced
        }
    }

    func request(
        _ metadata: ActionMetadata,
        action: @escaping @MainActor () -> Void
    ) {
        if metadata.requirement == .policy, policyProvider() == .balanced {
            action()
            return
        }

        pendingRequest = PendingRequest(metadata: metadata, action: action)
    }

    func confirmPendingRequest() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        request.action()
    }

    func cancelPendingRequest() {
        pendingRequest = nil
    }

    func dismissPendingRequest() {
        pendingRequest = nil
    }
}
