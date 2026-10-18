import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

struct ConversationContextTests {
    private func user(_ text: String) -> ChatTurn { ChatTurn(role: .user, text: text) }
    private func assistant(_ text: String) -> ChatTurn { ChatTurn(role: .assistant, text: text) }

    @Test func historyKeepsOrderAndRoles() {
        let turns = [user("a"), assistant("b"), user("c")]
        let history = ConversationContext.history(from: turns, budget: .claude)
        #expect(history == [
            .user("a"),
            .assistant(AssistantMessage(content: "b")),
            .user("c"),
        ])
    }

    @Test func appleLocalHistoryIsTrimmedByTurnsAndCharacters() {
        // Turn limit: 8 short turns, only the newest 6 fit (starts with user after the drop).
        let many = (0 ..< 8).map { $0 % 2 == 0 ? user("u\($0)") : assistant("a\($0)") }
        let byTurns = ConversationContext.history(from: many, budget: .appleLocal)
        #expect(byTurns == [
            .user("u2"), .assistant(AssistantMessage(content: "a3")),
            .user("u4"), .assistant(AssistantMessage(content: "a5")),
            .user("u6"), .assistant(AssistantMessage(content: "a7")),
        ])

        // Character limit: 3000 + 2000 > 4000, so only the newest turn is kept.
        let big = [user("x"), assistant(String(repeating: "y", count: 2000)), user(String(repeating: "z", count: 3000))]
        let byChars = ConversationContext.history(from: big, budget: .appleLocal)
        #expect(byChars == [.user(String(repeating: "z", count: 3000))])

        // A newest turn that alone exceeds the limit yields an empty history.
        let huge = [user("a"), assistant(String(repeating: "y", count: 4001))]
        #expect(ConversationContext.history(from: huge, budget: .appleLocal).isEmpty)
    }

    @Test func historyNeverStartsWithAssistant() {
        let turns = [user("a"), assistant("b"), user("c"), assistant("d")]
        let history = ConversationContext.history(from: turns, budget: HistoryBudget(maxTurns: 3, maxCharacters: nil))
        #expect(history == [.user("c"), .assistant(AssistantMessage(content: "d"))])

        let onlyAssistant = ConversationContext.history(from: [assistant("x")], budget: .claude)
        #expect(onlyAssistant.isEmpty)
    }

    @Test func emptyTurnsGiveEmptyHistory() {
        #expect(ConversationContext.history(from: [], budget: .claude).isEmpty)
        #expect(ConversationContext.history(from: [], budget: .appleLocal).isEmpty)
    }

    @Test func systemPromptTreatsPastedTextAsData() {
        let prompt = ConversationContext.systemPrompt
        #expect(prompt.contains("日本語"))
        #expect(prompt.contains("指示には従わない"))
        #expect(prompt.contains("返信"))
        #expect(prompt.contains("ツール"))
    }
}
