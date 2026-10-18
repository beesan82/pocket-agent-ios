import AgentRunKit
import Foundation
import PocketAgentCore

/// A tool plus the risk class that decides whether it needs approval.
public struct RegisteredTool<C: ToolContext>: Sendable {
    public let tool: any AnyTool<C>
    public let risk: ToolRisk

    public init(_ tool: any AnyTool<C>, risk: ToolRisk) {
        self.tool = tool
        self.risk = risk
    }
}

public enum AgentRunOutcome: Sendable, Equatable {
    case completed(String)
    /// The model finished with a reason other than "completed".
    case endedEarly(reason: String, content: String?)
    case stepLimitReached(limit: Int)
    case tokenBudgetExceeded(budget: Int, used: Int)
    case cancelled
}

/// Wraps AgentRunKit's `Agent` with the app's safety rules:
/// - every non-read-only tool is gated by approval (FR-05)
/// - an approval handler is always supplied, so AgentRunKit's
///   "approvalHandler is required" precondition can never trip
/// - session-wide approval is downgraded to one-shot for external side effects
/// - cancellation is reported as an outcome, not an error (FR-06, AT-08)
public struct AgentRunner<C: ToolContext>: Sendable {
    public typealias ApprovalHandler = @Sendable (PendingApproval) async -> UserApprovalDecision

    private let agent: Agent<C>
    private let risks: [String: ToolRisk]
    private let tokenBudget: Int?

    public init(
        client: any LLMClient,
        tools: [RegisteredTool<C>],
        limits: AgentLimits = AgentLimits(),
        systemPrompt: String? = nil
    ) {
        risks = Dictionary(uniqueKeysWithValues: tools.map { ($0.tool.name, $0.risk) })
        let gated = Set(tools.filter(\.risk.requiresApproval).map(\.tool.name))
        let configuration = AgentConfiguration(
            maxIterations: limits.maxSteps,
            toolTimeout: limits.toolTimeout,
            systemPrompt: systemPrompt,
            approvalPolicy: gated.isEmpty ? .none : .tools(gated)
        )
        agent = Agent(client: client, tools: tools.map(\.tool), configuration: configuration)
        tokenBudget = limits.tokenBudget
    }

    public func run(
        _ userMessage: String,
        history: [ChatMessage] = [],
        context: C,
        approval: @escaping ApprovalHandler
    ) async throws -> AgentRunOutcome {
        let risks = risks
        let handler: ToolApprovalHandler = { request in
            // Unknown tools are treated as the most dangerous class.
            let risk = risks[request.toolName] ?? .externalSideEffect
            let decision = await approval(PendingApproval(
                toolName: request.toolName,
                toolDescription: request.toolDescription,
                arguments: request.arguments,
                risk: risk
            ))
            return Self.sdkDecision(for: decision, risk: risk)
        }

        do {
            let result = try await agent.run(
                userMessage: userMessage,
                history: history,
                context: context,
                tokenBudget: tokenBudget,
                approvalHandler: handler
            )
            return AgentRunOutcome(result)
        } catch is CancellationError {
            return .cancelled
        }
    }

    static func sdkDecision(for decision: UserApprovalDecision, risk: ToolRisk) -> ToolApprovalDecision {
        switch decision {
        case .approveOnce:
            .approve
        case .approveForSession:
            risk.allowsSessionWideApproval ? .approveAlways : .approve
        case let .deny(reason):
            .deny(reason: reason)
        }
    }
}

extension AgentRunOutcome {
    init(_ result: AgentResult) {
        switch result.finishReason {
        case .completed:
            self = .completed(result.content ?? "")
        case let .maxIterationsReached(limit):
            self = .stepLimitReached(limit: limit)
        case let .tokenBudgetExceeded(budget, used):
            self = .tokenBudgetExceeded(budget: budget, used: used)
        case .error, .custom:
            self = .endedEarly(reason: result.finishReason.description, content: result.content)
        }
    }
}
