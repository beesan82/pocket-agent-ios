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

    public nonisolated func handler(
        asking user: @escaping ToolApprovalGate.ApprovalHandler
    ) -> ToolApprovalGate.ApprovalHandler {
        { request in await user(request) }
    }

    public func reset() {
        approvedTools.removeAll()
    }
}
