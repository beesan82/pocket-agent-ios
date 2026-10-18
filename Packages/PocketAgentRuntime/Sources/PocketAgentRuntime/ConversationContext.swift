import AgentRunKit
import Foundation
import PocketAgentCore

/// How much stored conversation is replayed to the model on each turn.
public struct HistoryBudget: Sendable {
    public let maxTurns: Int
    public let maxCharacters: Int?

    public init(maxTurns: Int, maxCharacters: Int?) {
        self.maxTurns = maxTurns
        self.maxCharacters = maxCharacters
    }

    public static let claude = HistoryBudget(maxTurns: 20, maxCharacters: nil)
    public static let appleLocal = HistoryBudget(maxTurns: 6, maxCharacters: 4000)
}

public enum ConversationContext {
    public static let systemPrompt: String = ""

    public static func history(from turns: [ChatTurn], budget: HistoryBudget) -> [ChatMessage] {
        []
    }
}
