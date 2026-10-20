import AgentRunKit
import Foundation
import PocketAgentCore
import PocketAgentRuntime
import SwiftData
import Testing
@testable import PocketAgent

/// FakeLLM for the app target (same pattern as the Runtime package's `ScriptedLLMClient`).
///
/// AgentRunKit 6.1.0 ends a run on plain text only for its own client types, so every
/// script ends with the reserved `finish` tool. `.runOwnTool` imitates
/// `FoundationModelsClient`, which executes its own tools inside `generate`.
/// With `foundationModelsContract`, requests are checked like AgentRunKit 6.1.0's
/// `FMMessageMapper`: leading system messages plus exactly one non-blank user message.
final class FakeLLMClient: LLMClient {
    enum Step: Sendable {
        case callTool(name: String, arguments: String)
        case runOwnTool(name: String, arguments: String)
        case finish(String)
    }

    enum FakeError: Error {
        case scriptExhausted
        case unknownOwnTool
        case streamingNotScripted
        case unsupportedMapping
    }

    let providerIdentifier: ProviderIdentifier = .custom("fake-llm")

    private let steps: [Step]
    private let ownTools: [any AnyTool<EmptyContext>]
    private let foundationModelsContract: Bool
    private let recorder = FakeRecorder()

    init(
        _ steps: [Step], ownTools: [any AnyTool<EmptyContext>] = [], foundationModelsContract: Bool = false
    ) {
        self.steps = steps
        self.ownTools = ownTools
        self.foundationModelsContract = foundationModelsContract
    }

    var requests: [[ChatMessage]] {
        get async { await recorder.requests }
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        let index = await recorder.record(messages)
        if foundationModelsContract { try Self.checkFoundationModelsMapping(messages) }
        guard index < steps.count else { throw FakeError.scriptExhausted }
        let callID = "call_\(index)"
        switch steps[index] {
        case let .callTool(name, arguments):
            return AssistantMessage(content: "", toolCalls: [ToolCall(id: callID, name: name, arguments: arguments)])
        case let .runOwnTool(name, arguments):
            guard let tool = ownTools.first(where: { $0.name == name }) else { throw FakeError.unknownOwnTool }
            let result = try await tool.execute(arguments: Data(arguments.utf8), context: EmptyContext())
            return Self.finish(callID, content: result.content)
        case let .finish(content):
            return Self.finish(callID, content: content)
        }
    }

    func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeError.streamingNotScripted) }
    }

    /// Mirrors `FMMessageMapper.map`: throws where the real on-device client would.
    private static func checkFoundationModelsMapping(_ messages: [ChatMessage]) throws {
        var sawUser = false
        func acceptUser(_ text: String) throws {
            guard !sawUser, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FakeError.unsupportedMapping
            }
            sawUser = true
        }
        for message in messages {
            switch message {
            case .system:
                guard !sawUser else { throw FakeError.unsupportedMapping }
            case let .user(text):
                try acceptUser(text)
            case let .userMultimodal(parts):
                let texts = try parts.map { part throws -> String in
                    guard case let .text(text) = part else { throw FakeError.unsupportedMapping }
                    return text
                }
                try acceptUser(texts.joined(separator: "\n"))
            case .assistant, .tool:
                throw FakeError.unsupportedMapping
            }
        }
        guard sawUser else { throw FakeError.unsupportedMapping }
    }

    private static func finish(_ callID: String, content: String) -> AssistantMessage {
        let data = (try? JSONSerialization.data(withJSONObject: ["content": content])) ?? Data()
        let arguments = String(decoding: data, as: UTF8.self)
        return AssistantMessage(content: "", toolCalls: [ToolCall(id: callID, name: "finish", arguments: arguments)])
    }
}

private actor FakeRecorder {
    private(set) var requests: [[ChatMessage]] = []

    func record(_ messages: [ChatMessage]) -> Int {
        requests.append(messages)
        return requests.count - 1
    }
}

@MainActor
struct ChatSessionTests {
    // Kept as a property: a ModelContext crashes if its container is released.
    private let container: ModelContainer
    private let repository: ConversationRepository
    private let settings: ModelSettings
    private let broker = ApprovalBroker()
    private let notes = InMemoryNoteStore()

    init() throws {
        container = try AppModelContainer.make(inMemory: true)
        repository = ConversationRepository(context: container.mainContext)
        let name = "ChatSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        settings = ModelSettings(defaults: defaults)
    }

    private func makeSession(
        _ conversation: ConversationRecord,
        notes customNotes: (any MemoryStore)? = nil,
        log: @escaping @MainActor (String) -> Void = { _ in },
        resolve: @escaping ClientResolver
    ) -> ChatSession {
        ChatSession(
            conversation: conversation, repository: repository, notes: customNotes ?? notes,
            settings: settings, broker: broker, resolve: resolve, log: log)
    }

    /// What the on-device model wrote on the iPhone instead of calling save_note.
    private static let rescuableSaveReply =
        "あなたの名前をメモとして保存します。\n```json\n{\"text\": \"あなたの名前はケイタ\"}\n```"

    /// Polls on the main actor; returns false on timeout instead of hanging the suite.
    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func json(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func completedTurnIsSavedAsAssistant() async throws {
        let conversation = try repository.create(choice: .claude)
        let fake = FakeLLMClient([.finish("こんにちは")])
        let session = makeSession(conversation) { _, _ in .success(fake) }

        session.send("やあ")

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        let expected = [ChatTurn(role: .user, text: "やあ"), ChatTurn(role: .assistant, text: "こんにちは")]
        #expect(session.turns == expected)
        #expect(repository.turns(of: conversation) == expected)
        // The system prompt goes in as a system message; history excludes the current user turn.
        let first = try #require(await fake.requests.first)
        #expect(first.first == .system(ConversationContext.systemPrompt))
        #expect(first.filter { if case .user = $0 { true } else { false } } == [.user("やあ")])
    }

    // AT-03: an unavailable on-device model is reported and the user turn stays.
    @Test func failedResolutionKeepsUserTurnAndShowsReason() async throws {
        settings.choice = .appleLocal
        let conversation = try repository.create(choice: .appleLocal)
        let credentials = SpyCredentialStore(key: "test-key")
        let resolve = ChatSession.liveResolver(
            credentials: credentials,
            availability: FixedAvailability(reason: .appleIntelligenceNotEnabled),
            settings: settings)
        let session = makeSession(conversation, resolve: resolve)

        session.send("予定覚えといて")

        let reason = ModelUnavailableReason.appleIntelligenceNotEnabled.userMessage
        #expect(try await waitUntil { session.status == .failed(reason) })
        #expect(session.turns == [ChatTurn(role: .user, text: "予定覚えといて")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "予定覚えといて")])
        #expect(credentials.reads == 0)
    }

    // AT-08: stopping while the approval dialog is open saves nothing.
    @Test func stopMarksCancelledAndSavesNoAssistantTurn() async throws {
        let conversation = try repository.create(choice: .claude)
        let fake = FakeLLMClient([
            .callTool(name: NoteToolName.save, arguments: Self.json(["text": "牛乳"])),
            .finish("保存しました")
        ])
        let session = makeSession(conversation) { _, _ in .success(fake) }

        session.send("牛乳を覚えといて")
        #expect(try await waitUntil { broker.pending != nil })
        session.stop()

        #expect(try await waitUntil { session.status == .failed("停止しました") })
        #expect(broker.pending == nil)
        #expect(session.turns == [ChatTurn(role: .user, text: "牛乳を覚えといて")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "牛乳を覚えといて")])
        #expect(try await notes.all().isEmpty)
    }

    @Test func deleteApprovalShowsNoteText() async throws {
        let note = try await notes.add("歯医者 10/20 15時")
        let conversation = try repository.create(choice: .claude)
        let fake = FakeLLMClient([
            .callTool(name: NoteToolName.delete, arguments: Self.json(["id": note.id.uuidString])),
            .finish("削除しました")
        ])
        let session = makeSession(conversation) { _, _ in .success(fake) }

        session.send("歯医者のメモ消して")
        #expect(try await waitUntil { broker.pending != nil })

        #expect(broker.pending?.summary == "歯医者 10/20 15時")
        #expect(broker.pending?.approval.toolName == NoteToolName.delete)
        broker.answer(.approveOnce)
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(try await notes.note(id: note.id) == nil)
    }

    // The conversation-wide allowance is shared by both tool paths and survives a model switch.
    @Test func sessionApprovalSurvivesModelSwitch() async throws {
        let conversation = try repository.create(choice: .claude)
        let claudeFake = FakeLLMClient([
            .callTool(name: NoteToolName.save, arguments: Self.json(["text": "一つ目"])),
            .finish("保存しました")
        ])
        let session = makeSession(conversation) { choice, appleLocalTools in
            let client: any LLMClient = switch choice {
            case .claude:
                claudeFake
            case .appleLocal, .mlxLocal:
                FakeLLMClient(
                    [.runOwnTool(name: NoteToolName.save, arguments: Self.json(["text": "二つ目"]))],
                    ownTools: appleLocalTools, foundationModelsContract: true)
            }
            return .success(client)
        }

        session.send("一つ目を覚えて")
        #expect(try await waitUntil { broker.pending != nil })
        broker.answer(.approveForSession)
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })

        settings.choice = .appleLocal
        session.send("二つ目も覚えて")
        #expect(try await waitUntil { session.status != .running || broker.pending != nil })

        #expect(broker.pending == nil)
        #expect(session.status == .idle)
        #expect(Set(try await notes.all().map(\.text)) == ["一つ目", "二つ目"])
        #expect(session.turns.count == 4)
    }

    // C1: the on-device client takes one prompt, so turn 2 must not replay history as messages.
    @Test func appleLocalSecondTurnSendsOneFoldedPrompt() async throws {
        settings.choice = .appleLocal
        let conversation = try repository.create(choice: .appleLocal)
        let fake = FakeLLMClient([.finish("一回目の答え"), .finish("二回目の答え")], foundationModelsContract: true)
        let session = makeSession(conversation) { _, _ in .success(fake) }

        session.send("一回目")
        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        session.send("二回目")
        #expect(try await waitUntil { session.status != .running })

        #expect(session.status == .idle)
        #expect(session.turns.count == 4)
        let requests = await fake.requests
        #expect(requests.count == 2)
        let second = try #require(requests.last)
        #expect(second.count == 2)
        #expect(second.first == .system(ConversationContext.systemPrompt))
        let expected = ConversationContext.appleLocalPrompt(
            history: [ChatTurn(role: .user, text: "一回目"), ChatTurn(role: .assistant, text: "一回目の答え")],
            message: "二回目")
        #expect(second.last == .user(expected))
        guard case let .user(prompt) = second.last else { return }
        #expect(prompt.contains("一回目の答え"))
        #expect(prompt.hasSuffix("二回目"))
        #expect(prompt != "二回目")
    }

    // MARK: - Memory injection

    @Test func memoryIsInjectedForClaudeAndAppleLocal() async throws {
        _ = try await notes.add("あなたの名前はケイタ")

        // Claude: memory follows the system prompt in the system message.
        let claude = FakeLLMClient([.finish("ケイタさんですね")])
        let claudeSession = makeSession(try repository.create(choice: .claude)) { _, _ in .success(claude) }
        claudeSession.send("私の名前は？")
        #expect(try await waitUntil { claudeSession.status == .idle })
        guard case let .system(system)? = await claude.requests.first?.first else {
            Issue.record("no system message")
            return
        }
        #expect(system.hasPrefix(ConversationContext.systemPrompt))
        #expect(system.contains("あなたの名前はケイタ"))

        // Apple local: memory goes into the user prompt, never the system message.
        settings.choice = .appleLocal
        let apple = FakeLLMClient([.finish("ケイタさんですね")], foundationModelsContract: true)
        let appleSession = makeSession(try repository.create(choice: .appleLocal)) { _, _ in .success(apple) }
        appleSession.send("私の名前は？")
        #expect(try await waitUntil { appleSession.status == .idle })
        let request = try #require(await apple.requests.first)
        #expect(request.first == .system(ConversationContext.systemPrompt))
        guard case let .user(prompt)? = request.last else {
            Issue.record("no user message")
            return
        }
        #expect(prompt.hasPrefix(ConversationContext.notesHeader))
        #expect(prompt.contains("あなたの名前はケイタ"))
        #expect(prompt.hasSuffix("私の名前は？"))
    }

    @Test func memoryReadFailureStillAnswers() async throws {
        let fake = FakeLLMClient([.finish("こんにちは")])
        let session = makeSession(try repository.create(choice: .claude), notes: ThrowingMemoryStore()) { _, _ in
            .success(fake)
        }

        session.send("やあ")

        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        #expect(session.turns.count == 2)
        #expect(session.turns.last?.text == "こんにちは")
        let first = try #require(await fake.requests.first)
        #expect(first.first == .system(ConversationContext.systemPrompt))
    }

    // MARK: - Tool-call rescue

    @Test func rescuedSaveAsksApprovalThenStores() async throws {
        settings.choice = .appleLocal
        let fake = FakeLLMClient([.finish(Self.rescuableSaveReply)], foundationModelsContract: true)
        let lines = LogLines()
        let session = ChatSession(
            conversation: try repository.create(choice: .appleLocal), repository: repository, notes: notes,
            settings: settings, broker: broker, resolve: { _, _ in .success(fake) }, log: { lines.append($0) })

        session.send("私の名前はケイタ 覚えておいて")
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.approval.toolName == NoteToolName.save)
        #expect(broker.pending?.summary == "あなたの名前はケイタ")
        broker.answer(.approveOnce)

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(session.turns.last?.text == "あなたの名前をメモとして保存します。\n\nメモを保存しました")
        #expect(try await notes.all().map(\.text) == ["あなたの名前はケイタ"])
        #expect(lines.entries == ["toolcall.rescued model=appleLocal tool=save_note"])
        #expect(!session.isToolSupportLimited)
    }

    @Test func deniedRescueKeepsReplyAndStoresNothing() async throws {
        settings.choice = .appleLocal
        let conversation = try repository.create(choice: .appleLocal)
        let fake = FakeLLMClient([.finish(Self.rescuableSaveReply)], foundationModelsContract: true)
        let lines = LogLines()
        let session = makeSession(conversation, log: { lines.append($0) }) { _, _ in .success(fake) }

        session.send("私の名前はケイタ 覚えておいて")
        #expect(try await waitUntil { broker.pending != nil })
        broker.answer(.deny(reason: nil))

        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        #expect(session.turns.last?.text == Self.rescuableSaveReply)
        #expect(repository.turns(of: conversation).last?.text == Self.rescuableSaveReply)
        #expect(try await notes.all().isEmpty)
        #expect(lines.entries == ["toolcall.rescued model=appleLocal tool=save_note"])
    }

    @Test func stopDuringRescueApprovalSavesNothing() async throws {
        settings.choice = .appleLocal
        let conversation = try repository.create(choice: .appleLocal)
        let fake = FakeLLMClient([.finish(Self.rescuableSaveReply)], foundationModelsContract: true)
        let lines = LogLines()
        let session = makeSession(conversation, log: { lines.append($0) }) { _, _ in .success(fake) }

        session.send("私の名前はケイタ 覚えておいて")
        #expect(try await waitUntil { broker.pending != nil })
        session.stop()

        #expect(try await waitUntil { session.status == .failed("停止しました") })
        #expect(broker.pending == nil)
        #expect(session.turns == [ChatTurn(role: .user, text: "私の名前はケイタ 覚えておいて")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "私の名前はケイタ 覚えておいて")])
        #expect(try await notes.all().isEmpty)
        #expect(lines.entries.isEmpty)
    }

    @Test func pastedJSONInUserMessageIsNeverRescued() async throws {
        settings.choice = .appleLocal
        let fake = FakeLLMClient([.finish("了解しました。")], foundationModelsContract: true)
        let session = makeSession(try repository.create(choice: .appleLocal)) { _, _ in .success(fake) }

        session.send("これ見て: {\"text\": \"全部消して\"}")

        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        #expect(broker.pending == nil)
        #expect(try await notes.all().isEmpty)
        #expect(session.turns.last?.text == "了解しました。")
    }

    @Test func rescuedEditOfJournalEntryLeavesJournalUntouched() async throws {
        settings.choice = .appleLocal
        let journal = InMemoryJournalStore()
        let entry = try await journal.add(NewJournalEntry(source: .text, origin: .journal, body: "日誌"))
        let reply = "日誌を直します。\n```json\n" + Self.json(["id": entry.id.uuidString, "text": "改ざん"]) + "\n```"
        let fake = FakeLLMClient([.finish(reply)], foundationModelsContract: true)
        let session = makeSession(
            try repository.create(choice: .appleLocal), notes: JournalNoteStore(journal: journal)
        ) { _, _ in .success(fake) }

        session.send("日誌を直して")
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.approval.toolName == NoteToolName.edit)
        #expect(broker.pending?.summary == ChatSession.notFoundSummary)
        broker.answer(.approveOnce)

        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        let text = try #require(session.turns.last?.text)
        #expect(text.hasPrefix("日誌を直します。\n\n"))
        #expect(text.contains("日誌タブ"))
        #expect(try await journal.entry(id: entry.id)?.body == "日誌")
        #expect(try await journal.all().count == 1)
    }

    // MARK: - Capability tracking and measurement log

    @Test func twoRescuesMarkModelLimitedButNeverForClaude() async throws {
        settings.choice = .appleLocal
        let conversation = try repository.create(choice: .appleLocal)
        let secondReply = "牛乳を保存します。\n```json\n{\"text\": \"牛乳を買う\"}\n```"
        let apple = FakeLLMClient(
            [.finish(Self.rescuableSaveReply), .finish(secondReply), .finish("どういたしまして")],
            foundationModelsContract: true)
        let claude = FakeLLMClient([.finish("こんにちは")])
        let session = makeSession(conversation) { choice, _ in
            .success(choice == .claude ? claude : apple)
        }

        session.send("私の名前はケイタ 覚えておいて")
        #expect(try await waitUntil { broker.pending != nil })
        broker.answer(.approveForSession)
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(!session.isToolSupportLimited)

        // "Allow for this conversation" also covers the second rescue: no new dialog.
        session.send("牛乳を買うのを覚えて")
        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        #expect(session.turns.count == 4)
        #expect(Set(try await notes.all().map(\.text)) == ["あなたの名前はケイタ", "牛乳を買う"])
        #expect(session.isToolSupportLimited)

        // Never shown for Claude.
        settings.choice = .claude
        session.send("こんにちは")
        #expect(!session.isToolSupportLimited)
        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        #expect(!session.isToolSupportLimited)

        // Back on the on-device model the evidence starts over.
        settings.choice = .appleLocal
        session.send("ありがとう")
        #expect(try await waitUntil { session.status != .running })
        #expect(session.status == .idle)
        #expect(session.turns.count == 8)
        #expect(!session.isToolSupportLimited)
    }

    @Test func missedMemoryIntentTwiceMarksLimited() async throws {
        settings.choice = .appleLocal
        let fake = FakeLLMClient([.finish("わかりました"), .finish("了解です")], foundationModelsContract: true)
        let lines = LogLines()
        let session = makeSession(try repository.create(choice: .appleLocal), log: { lines.append($0) }) { _, _ in
            .success(fake)
        }

        session.send("牛乳を覚えて")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(!session.isToolSupportLimited)
        session.send("歯医者をメモ")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 4 })

        #expect(session.isToolSupportLimited)
        #expect(lines.entries == ["toolcall.none model=appleLocal", "toolcall.none model=appleLocal"])
    }

    // The chat screen outlives a model switch in settings: the notice follows the current selection.
    @Test func limitedNoticeFollowsCurrentSelectionWithoutSending() async throws {
        settings.choice = .appleLocal
        let fake = FakeLLMClient([.finish("わかりました"), .finish("了解です")], foundationModelsContract: true)
        let session = makeSession(try repository.create(choice: .appleLocal)) { _, _ in .success(fake) }

        session.send("牛乳を覚えて")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        session.send("歯医者をメモ")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 4 })
        #expect(session.isToolSupportLimited)

        settings.choice = .claude
        #expect(!session.isToolSupportLimited)

        // No turn ran on another model, so the evidence for this model still stands.
        settings.choice = .appleLocal
        #expect(session.isToolSupportLimited)
    }

    // A native call the user denies is still a native call: the reply is not rescued and asked again.
    @Test func appleLocalDeniedNativeCallIsNotRescued() async throws {
        settings.choice = .appleLocal
        let lines = LogLines()
        let session = makeSession(try repository.create(choice: .appleLocal), log: { lines.append($0) }) {
            _, appleLocalTools in
            .success(FakeLLMClient(
                [.runOwnTool(name: NoteToolName.save, arguments: Self.json(["text": "牛乳"]))],
                ownTools: appleLocalTools, foundationModelsContract: true))
        }

        session.send("牛乳を覚えて")
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.approval.toolName == NoteToolName.save)
        broker.answer(.deny(reason: nil))

        // A second dialog (a rescue) would stop the wait with `pending` set.
        #expect(try await waitUntil { session.status != .running || broker.pending != nil })
        #expect(broker.pending == nil)
        #expect(session.status == .idle)
        #expect(session.turns.count == 2)
        #expect(try await notes.all().isEmpty)
        #expect(lines.entries == ["toolcall.native model=appleLocal tool=save_note"])
        #expect(!session.isToolSupportLimited)
    }

    @Test func nativeToolCallIsLoggedAsNative() async throws {
        let fake = FakeLLMClient([
            .callTool(name: NoteToolName.save, arguments: Self.json(["text": "牛乳"])),
            .finish("保存しました")
        ])
        let lines = LogLines()
        let session = makeSession(try repository.create(choice: .claude), log: { lines.append($0) }) { _, _ in
            .success(fake)
        }

        session.send("牛乳を覚えて")
        #expect(try await waitUntil { broker.pending != nil })
        broker.answer(.approveOnce)

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(lines.entries == ["toolcall.native model=claude tool=save_note"])
        #expect(try await notes.all().map(\.text) == ["牛乳"])
        #expect(!session.isToolSupportLimited)
    }

    // The fake on-device client echoes the tool result (`{"id":…,"text":…}`) as its reply,
    // which looks like an edit_note call: a turn with a native call must never be rescued.
    @Test func appleLocalNativeCallIsLoggedAndNotRescued() async throws {
        settings.choice = .appleLocal
        let lines = LogLines()
        let session = makeSession(try repository.create(choice: .appleLocal), log: { lines.append($0) }) {
            _, appleLocalTools in
            .success(FakeLLMClient(
                [.runOwnTool(name: NoteToolName.save, arguments: Self.json(["text": "牛乳"]))],
                ownTools: appleLocalTools, foundationModelsContract: true))
        }

        session.send("牛乳を覚えて")
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.approval.toolName == NoteToolName.save)
        broker.answer(.approveOnce)

        #expect(try await waitUntil { session.status != .running || broker.pending != nil })
        #expect(broker.pending == nil)
        #expect(session.status == .idle)
        #expect(try await notes.all().map(\.text) == ["牛乳"])
        #expect(lines.entries == ["toolcall.native model=appleLocal tool=save_note"])
    }

    @Test func approvalSummaries() async throws {
        let note = try await notes.add("買い物リスト")
        func request(_ name: String, _ arguments: String) -> PendingApproval {
            PendingApproval(toolName: name, toolDescription: "", arguments: arguments, risk: .appInternalWrite)
        }

        #expect(await ChatSession.summary(
            for: request(NoteToolName.save, Self.json(["text": "保存する本文"])), notes: notes) == "保存する本文")
        #expect(await ChatSession.summary(for: request(NoteToolName.save, "not json"), notes: notes) == "not json")
        #expect(await ChatSession.summary(
            for: request(NoteToolName.delete, Self.json(["id": note.id.uuidString])), notes: notes) == "買い物リスト")
        #expect(await ChatSession.summary(
            for: request(NoteToolName.delete, Self.json(["id": UUID().uuidString])), notes: notes)
            == "該当するメモがありません")
        #expect(await ChatSession.summary(
            for: request(NoteToolName.delete, Self.json(["id": "x"])), notes: notes) == "該当するメモがありません")
        #expect(await ChatSession.summary(
            for: request(NoteToolName.edit, Self.json(["id": note.id.uuidString, "text": "新しい本文"])), notes: notes)
            == "買い物リスト → 新しい本文")
        #expect(await ChatSession.summary(
            for: request(NoteToolName.edit, Self.json(["id": UUID().uuidString, "text": "x"])), notes: notes)
            == "該当するメモがありません")
        #expect(await ChatSession.summary(for: request(NoteToolName.edit, "not json"), notes: notes) == "not json")
        #expect(await ChatSession.summary(for: request("other_tool", "{\"a\":1}"), notes: notes) == "{\"a\":1}")
    }

    @Test func blankInputIsIgnored() throws {
        let conversation = try repository.create(choice: .claude)
        let session = makeSession(conversation) { _, _ in .success(FakeLLMClient([.finish("x")])) }

        session.send("   \n")

        #expect(session.turns.isEmpty)
        #expect(session.status == .idle)
    }
}

@MainActor
struct ApprovalBrokerTests {
    private static let request = PendingApproval(
        toolName: "save_note", toolDescription: "", arguments: "{}", risk: .appInternalWrite)

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func answerResumesAndClearsPending() async throws {
        let broker = ApprovalBroker()
        let task = Task { await broker.ask(Self.request, summary: "本文") }
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.summary == "本文")

        broker.answer(.approveOnce)

        #expect(await task.value == .approveOnce)
        #expect(broker.pending == nil)
        broker.answer(.approveOnce) // nothing pending: no-op
    }

    @Test func cancellingDeniesOnce() async throws {
        let broker = ApprovalBroker()
        let task = Task { await broker.ask(Self.request, summary: "本文") }
        #expect(try await waitUntil { broker.pending != nil })

        task.cancel()

        #expect(await task.value == .deny(reason: nil))
        #expect(broker.pending == nil)
    }

    @Test func secondAskWaitsForFirst() async throws {
        let broker = ApprovalBroker()
        let first = Task { await broker.ask(Self.request, summary: "一つ目") }
        #expect(try await waitUntil { broker.pending?.summary == "一つ目" })
        let second = Task { await broker.ask(Self.request, summary: "二つ目") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(broker.pending?.summary == "一つ目")

        broker.answer(.approveOnce)
        #expect(await first.value == .approveOnce)
        #expect(try await waitUntil { broker.pending?.summary == "二つ目" })
        broker.answer(.deny(reason: nil))
        #expect(await second.value == .deny(reason: nil))
        #expect(broker.pending == nil)
    }

    // I1: closing A's sheet must never deny a successor request B.
    @Test func denyByIDResolvesOnlyThatRequest() async throws {
        let broker = ApprovalBroker()
        let first = Task { await broker.ask(Self.request, summary: "一つ目") }
        #expect(try await waitUntil { broker.pending != nil })
        let firstID = try #require(broker.pending?.id)
        broker.answer(.approveOnce)
        #expect(await first.value == .approveOnce)

        let second = Task { await broker.ask(Self.request, summary: "二つ目") }
        #expect(try await waitUntil { broker.pending != nil })
        let secondID = try #require(broker.pending?.id)

        broker.deny(id: firstID) // already answered: no-op
        broker.deny(id: UUID()) // never asked: no-op
        #expect(broker.pending?.id == secondID)

        broker.deny(id: secondID)
        let resolved = broker.pending == nil
        #expect(resolved)
        if !resolved { broker.answer(.approveOnce) } // never leave the task hanging
        #expect(await second.value == .deny(reason: nil))
    }
}

@MainActor
struct RunFailureTextTests {
    // M2: the model's finish reason is never shown.
    @Test func endedEarlyShowsFixedText() {
        let text = RunFailureText.message(for: .endedEarly(reason: "provider body", content: "partial"))
        #expect(text == "応答が途中で終了しました")
    }
}
