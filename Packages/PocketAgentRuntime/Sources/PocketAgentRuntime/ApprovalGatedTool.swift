import AgentRunKit
import Foundation
import PocketAgentCore

// RED stub: signatures only. Behaviour is deliberately wrong.

public enum ToolApprovalGate {
    public typealias ApprovalHandler = @Sendable (PendingApproval) async -> UserApprovalDecision

    public static func wrap<C: ToolContext>(
        _ tools: [RegisteredTool<C>],
        approval: @escaping ApprovalHandler
    ) -> [any AnyTool<C>] {
        tools.map(\.tool)
    }
}
