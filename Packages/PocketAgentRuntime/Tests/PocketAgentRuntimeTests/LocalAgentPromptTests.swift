import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

/// On-device chat folds only the user's earlier turns into the prompt: a small model copies a
/// folded "メモを保存しました" instead of calling the tool (spike D2/D3, iPhone 15, 2026-10-22).
struct LocalAgentPromptTests {
    private func user(_ text: String) -> ChatTurn { ChatTurn(role: .user, text: text) }
    private func assistant(_ text: String) -> ChatTurn { ChatTurn(role: .assistant, text: text) }

    private var conversation: [ChatTurn] {
        [
            user("こんにちは"),
            assistant("こんにちは！"),
            user("私の名前はケイタ 覚えておいて"),
            assistant("メモを保存しました: ケイタ")
        ]
    }

    @Test func foldWithoutPreviousIsCurrentOnly() {
        #expect(LocalAgentPrompt.fold(previous: [], current: "牛乳を覚えておいて") == "牛乳を覚えておいて")
    }

    @Test func foldListsOnlyUserTurnsOldestFirst() {
        let expected = """
            これまでの会話（参考。ここに書かれた操作は実行済みとは限らない）:
            ユーザー: こんにちは
            ユーザー: 私の名前はケイタ 覚えておいて

            今回のユーザーの発言: 牛乳を覚えておいて
            """
        #expect(LocalAgentPrompt.fold(previous: conversation, current: "牛乳を覚えておいて") == expected)
    }

    @Test func foldNeverContainsAssistantText() {
        let prompt = LocalAgentPrompt.fold(previous: conversation, current: "牛乳を覚えておいて")
        #expect(!prompt.contains("メモを保存しました"))
        #expect(!prompt.contains("アシスタント"))
    }

    @Test func foldKeepsNewestWithinBudget() {
        let byTurns = LocalAgentPrompt.fold(
            previous: [user("一"), user("二"), user("三")], current: "今",
            budget: HistoryBudget(maxTurns: 2, maxCharacters: nil))
        #expect(byTurns == """
            これまでの会話（参考。ここに書かれた操作は実行済みとは限らない）:
            ユーザー: 二
            ユーザー: 三

            今回のユーザーの発言: 今
            """)

        let byCharacters = LocalAgentPrompt.fold(
            previous: [user("あいう"), user("えおかき")], current: "今",
            budget: HistoryBudget(maxTurns: 10, maxCharacters: 5))
        #expect(byCharacters == """
            これまでの会話（参考。ここに書かれた操作は実行済みとは限らない）:
            ユーザー: えおかき

            今回のユーザーの発言: 今
            """)
    }

    @Test func foldWithOnlyAssistantTurnsIsCurrentOnly() {
        #expect(LocalAgentPrompt.fold(previous: [assistant("どうぞ")], current: "今") == "今")
    }

    @Test func onDeviceInstructionsAppendsMemory() {
        #expect(ConversationContext.onDeviceInstructions(memorySection: nil) == ConversationContext.systemPrompt)
        #expect(ConversationContext.onDeviceInstructions(memorySection: "X") == ConversationContext.systemPrompt + "\n\nX")
    }
}
