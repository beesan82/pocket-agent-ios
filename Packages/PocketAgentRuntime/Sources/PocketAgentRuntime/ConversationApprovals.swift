import Foundation
import PocketAgentCore

/// Remembers "allow for this conversation" across agent runs.
///
/// AgentRunKit keeps its session allowlist per `Agent.run`, so the app keeps its own
/// per-conversation store and wraps the user's handler with it. Pass the wrapped handler
/// to both `AgentRunner.run(approval:)` and `ToolApprovalGate.wrap(_:approval:)`.
public actor ConversationApprovals {
    private var approvedTools: Set<String> = []

    public init() {}

    /// The decision is passed through unchanged, so downstream downgrade rules still apply.
    public nonisolated func handler(
        asking user: @escaping ToolApprovalGate.ApprovalHandler
    ) -> ToolApprovalGate.ApprovalHandler {
        { [self] request in
            if await isApproved(request.toolName) { return .approveOnce }
            let decision = await user(request)
            if decision == .approveForSession, request.risk.allowsSessionWideApproval {
                await record(request.toolName)
            }
            return decision
        }
    }

    public func reset() {
        approvedTools.removeAll()
    }

    private func isApproved(_ toolName: String) -> Bool {
        approvedTools.contains(toolName)
    }

    private func record(_ toolName: String) {
        approvedTools.insert(toolName)
    }
}
