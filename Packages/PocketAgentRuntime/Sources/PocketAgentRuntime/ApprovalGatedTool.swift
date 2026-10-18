import AgentRunKit
import Foundation
import PocketAgentCore

/// Approval for tools that run outside `Agent`'s loop.
///
/// `FoundationModelsClient` executes its tools inside the Foundation Models session,
/// so AgentRunKit's approval policy never sees them (ADR-009). Wrapping each tool puts
/// the same rules as `AgentRunner` in front of `execute`:
/// - non-read-only tools ask first (FR-05)
/// - "allow for session" is downgraded to one-shot for external side effects
/// - cancellation while the dialog is open throws, and the tool does not run (AT-08)
public enum ToolApprovalGate {
    public typealias ApprovalHandler = @Sendable (PendingApproval) async -> UserApprovalDecision

    /// Session approvals are shared by the returned tools only: call once per conversation.
    public static func wrap<C: ToolContext>(
        _ tools: [RegisteredTool<C>],
        approval: @escaping ApprovalHandler
    ) -> [any AnyTool<C>] {
        let session = SessionApprovals(handler: approval)
        return tools.map { ApprovalGatedTool(inner: $0.tool, risk: $0.risk, session: session) }
    }
}

struct ApprovalGatedTool<C: ToolContext>: AnyTool {
    typealias Context = C

    let inner: any AnyTool<C>
    let risk: ToolRisk
    let session: SessionApprovals

    var name: String { inner.name }
    var description: String { inner.description }
    var parametersSchema: JSONSchema { inner.parametersSchema }
    var isConcurrencySafe: Bool { inner.isConcurrencySafe }
    var isReadOnly: Bool { risk == .readOnly }
    var maxResultCharacters: Int? { inner.maxResultCharacters }
    var toolTimeout: Duration? { inner.toolTimeout }
    var strict: Bool? { inner.strict }

    func execute(arguments: Data, context: C) async throws -> ToolResult {
        if risk.requiresApproval {
            let request = PendingApproval(
                toolName: inner.name,
                toolDescription: inner.description,
                arguments: String(decoding: arguments, as: UTF8.self),
                risk: risk
            )
            if case let .denied(reason) = try await session.authorize(request) {
                return .error("Tool call denied by user" + (reason.map { ": \($0)" } ?? "."))
            }
        }
        return try await inner.execute(arguments: arguments, context: context)
    }
}

actor SessionApprovals {
    enum Verdict: Equatable {
        case approved
        case denied(String?)
    }

    private let handler: ToolApprovalGate.ApprovalHandler
    private var approvedForSession: Set<String> = []

    init(handler: @escaping ToolApprovalGate.ApprovalHandler) {
        self.handler = handler
    }

    func authorize(_ request: PendingApproval) async throws -> Verdict {
        if approvedForSession.contains(request.toolName) { return .approved }
        let decision = await handler(request)
        // The user may have stopped the task while the dialog was open.
        try Task.checkCancellation()
        switch decision {
        case .approveOnce:
            return .approved
        case .approveForSession:
            if request.risk.allowsSessionWideApproval {
                approvedForSession.insert(request.toolName)
            }
            return .approved
        case let .deny(reason):
            return .denied(reason)
        }
    }
}
