import Foundation
import Observation
import PocketAgentCore

/// What the approval sheet shows: the request plus a human-readable summary.
struct PendingApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let approval: PendingApproval
    let summary: String
}

@MainActor
@Observable
final class ApprovalBroker {
    private(set) var pending: PendingApprovalRequest?

    func ask(_ request: PendingApproval, summary: String) async -> UserApprovalDecision {
        .approveOnce
    }

    func answer(_ decision: UserApprovalDecision) {}
}
