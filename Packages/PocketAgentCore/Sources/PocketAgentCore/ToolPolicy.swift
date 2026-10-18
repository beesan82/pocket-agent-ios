import Foundation

/// How much a tool can affect the world outside the conversation (requirements §7).
public enum ToolRisk: String, Sendable, CaseIterable {
    /// Reads only what the user explicitly handed to the app.
    case readOnly
    /// Writes inside the app sandbox only (e.g. saving a note).
    case appInternalWrite
    /// Removes data inside the app sandbox (e.g. deleting a note). Approved per call, never session-wide.
    case appInternalDelete
    /// Leaves the app or reaches another service (e.g. opening LINE's share sheet).
    case externalSideEffect

    public var requiresApproval: Bool {
        self != .readOnly
    }

    /// "Allow for this session" is never honoured for actions that leave the app,
    /// so every LINE share needs its own confirmation (FR-05, duplicate-share guard).
    public var allowsSessionWideApproval: Bool {
        self == .appInternalWrite
    }
}

/// What the approval dialog shows the user. Independent of any agent SDK.
public struct PendingApproval: Sendable, Equatable {
    public let toolName: String
    public let toolDescription: String
    /// Raw JSON arguments proposed by the model. Treat as untrusted input.
    public let arguments: String
    public let risk: ToolRisk

    public init(toolName: String, toolDescription: String, arguments: String, risk: ToolRisk) {
        self.toolName = toolName
        self.toolDescription = toolDescription
        self.arguments = arguments
        self.risk = risk
    }
}

public enum UserApprovalDecision: Sendable, Equatable {
    case approveOnce
    case approveForSession
    case deny(reason: String?)
}

/// Per-task limits (FR-06). Defaults follow requirements §7: 10 agent steps.
public struct AgentLimits: Sendable, Equatable {
    public static let defaultMaxSteps = 10

    public let maxSteps: Int
    public let toolTimeout: Duration
    public let tokenBudget: Int?

    public init(
        maxSteps: Int = AgentLimits.defaultMaxSteps,
        toolTimeout: Duration = .seconds(30),
        tokenBudget: Int? = nil
    ) {
        self.maxSteps = max(1, maxSteps)
        self.toolTimeout = toolTimeout
        self.tokenBudget = tokenBudget.map { max(1, $0) }
    }
}
