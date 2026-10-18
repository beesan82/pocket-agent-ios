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
    }

    let providerIdentifier: ProviderIdentifier = .custom("fake-llm")

    private let steps: [Step]
    private let ownTools: [any AnyTool<EmptyContext>]
    private let recorder = FakeRecorder()

    init(_ steps: [Step], ownTools: [any AnyTool<EmptyContext>] = []) {
        self.steps = steps
        self.ownTools = ownTools
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
        resolve: @escaping ClientResolver
    ) -> ChatSession {
        ChatSession(
            conversation: conversation, repository: repository, notes: notes,
            settings: settings, broker: broker, resolve: resolve)
    }

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
            case .appleLocal:
                FakeLLMClient(
                    [.runOwnTool(name: NoteToolName.save, arguments: Self.json(["text": "二つ目"]))],
                    ownTools: appleLocalTools)
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
}
