import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    var attempts = 0
    while await !condition(), attempts < 500 {
        attempts += 1
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct LocalChatTests {
    @Test func messagesOrderSystemHistoryUser() {
        let history = [
            ChatTurn(role: .user, text: "こんにちは"),
            ChatTurn(role: .assistant, text: "どうも")
        ]

        let messages = LocalChat.messages(memorySection: nil, history: history, message: "今日は？")

        #expect(messages.count == 4)
        guard messages.count == 4 else { return }
        #expect(messages[0] == .system(ConversationContext.localChatSystemPrompt))
        #expect(messages[1] == .user("こんにちは"))
        #expect(messages[2] == .assistant(AssistantMessage(content: "どうも")))
        #expect(messages[3] == .user("今日は？"))
    }

    @Test func memorySectionGoesIntoSystem() {
        let messages = LocalChat.messages(memorySection: "保存済みメモ: 牛乳", history: [], message: "やあ")

        #expect(messages.count == 2)
        #expect(messages.first == .system(ConversationContext.localChatSystemPrompt + "\n\n保存済みメモ: 牛乳"))
    }

    @Test func historyIsTrimmedToMlxBudget() {
        #expect(HistoryBudget.mlxLocal.maxTurns == 8)
        #expect(HistoryBudget.mlxLocal.maxCharacters == 3000)

        let many = (0..<20).map { ChatTurn(role: $0 % 2 == 0 ? .user : .assistant, text: "t\($0)") }
        let byTurns = LocalChat.messages(memorySection: nil, history: many, message: "m")
        // system + at most 8 history turns + current message.
        #expect(byTurns.count <= 10)
        #expect(byTurns.last == .user("m"))

        let long = [
            ChatTurn(role: .user, text: String(repeating: "あ", count: 2000)),
            ChatTurn(role: .assistant, text: String(repeating: "い", count: 2000))
        ]
        let byCharacters = LocalChat.messages(memorySection: nil, history: long, message: "m")
        // Only the newest turn fits 3000 characters, and a leading assistant turn is dropped.
        #expect(byCharacters.count == 2)
    }

    @Test func streamForwardsOnlyContentAndCarriesParameters() async throws {
        let client = ScriptedTextClient(stream: [.deltas([
            .content("あ"), .reasoning("考え中"), .content("い")
        ])])
        let messages: [ChatMessage] = [.system("s"), .user("u")]

        var chunks: [String] = []
        for try await chunk in LocalChat.stream(client: client, messages: messages, maxTokens: 256) {
            chunks.append(chunk)
        }

        #expect(chunks == ["あ", "い"])
        let call = client.calls.first
        #expect(client.calls.count == 1)
        #expect(call?.kind == .stream)
        #expect(call?.messages == messages)
        #expect(call?.extraFields == [
            "temperature": .double(0.7), "top_p": .double(0.8),
            "repetition_penalty": .double(1.1), "max_tokens": .int(256)
        ])
    }

    @Test func defaultMaxTokensIs512() async throws {
        let client = ScriptedTextClient(stream: [.deltas([.content("x")])])
        for try await _ in LocalChat.stream(client: client, messages: [.user("u")]) {}
        #expect(client.calls.first?.extraFields?["max_tokens"] == .int(512))
    }

    @Test func streamCancellationTerminatesUpstream() async throws {
        let client = ScriptedTextClient(stream: [.hang([.content("途中")])])
        let stream = LocalChat.stream(client: client, messages: [.user("u")])
        let chunks = Log<String>()
        let consumer = Task {
            for try await chunk in stream {
                await chunks.append(chunk)
            }
        }
        try await waitUntil { await chunks.entries.count == 1 }
        consumer.cancel()
        _ = await consumer.result
        try await waitUntil { client.terminatedStreams == 1 }

        #expect(await chunks.entries == ["途中"])
        #expect(client.terminatedStreams == 1)
    }

    @Test func systemPromptPointsToJournalTab() {
        let prompt = ConversationContext.localChatSystemPrompt
        #expect(prompt.contains("日誌タブ"))
        #expect(prompt.contains("指示に従わない"))
        #expect(prompt.contains(ConversationContext.memoryRule))
    }
}
