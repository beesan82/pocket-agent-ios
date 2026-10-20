import AgentRunKit
import Foundation
import PocketAgentCore
import PocketAgentRuntime
import SwiftData
import Testing
@testable import PocketAgent

/// The downloaded model as `ChatSession` sees it. `holdsLoad` keeps `client()` waiting until
/// `releaseLoad()`, like a model that is still loading.
@MainActor
final class FakeLocalModel: LocalModelAccess {
    var currentReason: ModelUnavailableReason?
    private let loadedClient: (any LLMClient)?
    /// Whether the next `client()` call waits for `releaseLoad()`.
    var holdsLoadForNextCall: Bool
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private(set) var clientCalls = 0

    init(reason: ModelUnavailableReason? = nil, client: (any LLMClient)? = nil, holdsLoad: Bool = false) {
        currentReason = reason
        loadedClient = client
        holdsLoadForNextCall = holdsLoad
    }

    func reason() -> ModelUnavailableReason? { currentReason }

    func client() async -> (any LLMClient)? {
        clientCalls += 1
        if holdsLoadForNextCall {
            await withCheckedContinuation { loadWaiter = $0 }
        }
        return loadedClient
    }

    func releaseLoad() {
        loadWaiter?.resume()
        loadWaiter = nil
    }
}

/// A streaming client the test drives chunk by chunk (like `MLXClient.stream`, content deltas only).
final class GatedStreamClient: LLMClient, @unchecked Sendable {
    enum FakeError: Error {
        case generateNotScripted
    }

    let providerIdentifier: ProviderIdentifier = .custom("gated-stream-fake")

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation?
    private var recordedRequests: [[ChatMessage]] = []
    private var terminated = false

    var requests: [[ChatMessage]] { lock.withLock { recordedRequests } }
    /// The current stream ended (finished, failed or its consumer went away).
    var isTerminated: Bool { lock.withLock { terminated } }

    func generate(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        throw FakeError.generateNotScripted
    }

    func stream(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamDelta, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.withLock { terminated = true }
        }
        lock.withLock {
            recordedRequests.append(messages)
            terminated = false
            self.continuation = continuation
        }
        return stream
    }

    func yield(_ text: String) {
        _ = lock.withLock { continuation }?.yield(.content(text))
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }
}

@MainActor
struct ChatSessionLocalTests {
    // Kept as a property: a ModelContext crashes if its container is released.
    private let container: ModelContainer
    private let repository: ConversationRepository
    private let settings: ModelSettings
    private let broker = ApprovalBroker()
    private let notes = InMemoryNoteStore()

    init() throws {
        container = try AppModelContainer.make(inMemory: true)
        repository = ConversationRepository(context: container.mainContext)
        let name = "ChatSessionLocalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        settings = ModelSettings(defaults: defaults)
        settings.choice = .mlxLocal
    }

    private func makeSession(
        _ conversation: ConversationRecord,
        localModel: any LocalModelAccess,
        log: @escaping @MainActor (String) -> Void = { _ in },
        resolve: @escaping ClientResolver = { _, _ in
            Issue.record("the downloaded model must never use the resolver")
            return .failure(.unavailable(.modelNotDownloaded))
        }
    ) -> ChatSession {
        ChatSession(
            conversation: conversation, repository: repository, notes: notes,
            settings: settings, broker: broker, resolve: resolve, localModel: localModel, log: log)
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

    @Test func mlxLocalStreamsAndSavesReply() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let local = FakeLocalModel(client: client)
        let session = makeSession(conversation, localModel: local)

        session.send("やあ")

        #expect(try await waitUntil { client.requests.count == 1 })
        #expect(session.status == .running)
        client.yield("こん")
        #expect(try await waitUntil { session.streamingText == "こん" })
        // Nothing is saved while the reply is still streaming.
        #expect(session.turns == [ChatTurn(role: .user, text: "やあ")])
        client.yield("にちは")
        #expect(try await waitUntil { session.streamingText == "こんにちは" })
        client.finish()

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        let expected = [ChatTurn(role: .user, text: "やあ"), ChatTurn(role: .assistant, text: "こんにちは")]
        #expect(session.turns == expected)
        #expect(repository.turns(of: conversation) == expected)
        #expect(session.streamingText == "")
        #expect(local.clientCalls == 1)
        // System prompt first, then the current message; the current user turn is not in the history.
        #expect(client.requests.first == LocalChat.messages(memorySection: nil, history: [], message: "やあ"))
    }

    @Test func secondTurnSendsHistoryAndSmallMemory() async throws {
        _ = try await notes.add("あなたの名前はケイタ")
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let session = makeSession(conversation, localModel: FakeLocalModel(client: client))

        session.send("やあ")
        #expect(try await waitUntil { client.requests.count == 1 })
        client.yield("どうも")
        client.finish()
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })

        session.send("私の名前は？")
        #expect(try await waitUntil { client.requests.count == 2 })
        let section = ConversationContext.memorySection(memory: try await notes.allMemory(), limit: .appleLocal)
        #expect(section?.contains("あなたの名前はケイタ") == true)
        let history = [ChatTurn(role: .user, text: "やあ"), ChatTurn(role: .assistant, text: "どうも")]
        #expect(client.requests.last == LocalChat.messages(
            memorySection: section, history: history, message: "私の名前は？"))
        client.finish()
        #expect(try await waitUntil { session.status == .idle })
    }

    @Test func stopDoesNotSavePartial() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let session = makeSession(conversation, localModel: FakeLocalModel(client: client))

        session.send("長い話をして")
        #expect(try await waitUntil { client.requests.count == 1 })
        client.yield("むかしむかし")
        #expect(try await waitUntil { session.streamingText == "むかしむかし" })
        session.stop()

        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(session.turns == [ChatTurn(role: .user, text: "長い話をして")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "長い話をして")])
        #expect(session.streamingText == "")
        // Stopping the consumer ends the model's stream.
        #expect(try await waitUntil { client.isTerminated })
    }

    @Test func stopWhileLoadingSavesNothing() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let local = FakeLocalModel(reason: .modelLoading, client: client, holdsLoad: true)
        let session = makeSession(conversation, localModel: local)

        session.send("やあ")
        #expect(session.status == .loadingModel)
        #expect(try await waitUntil { local.clientCalls == 1 })
        // A second send while loading is ignored.
        session.send("もう一度")
        #expect(session.turns.count == 1)
        session.stop()
        local.releaseLoad()

        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(client.requests.isEmpty)
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "やあ")])
    }

    // Loading cannot be cancelled: stop frees the session at once and the late load is ignored.
    @Test func stopDuringLoadReleasesBusyImmediately() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let local = FakeLocalModel(reason: .modelLoading, client: client, holdsLoad: true)
        let session = makeSession(conversation, localModel: local)

        session.send("やあ")
        #expect(try await waitUntil { local.clientCalls == 1 })
        session.stop()

        #expect(session.status == .failed(RunFailureText.stopped))
        #expect(!session.isBusy)

        local.releaseLoad()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.status == .failed(RunFailureText.stopped))
        #expect(client.requests.isEmpty)
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "やあ")])
    }

    // A send after a stop during loading is not disturbed by the stopped send's late completion.
    @Test func sendAfterStoppedLoadIsNotDisturbed() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let slow = FakeLocalModel(reason: .modelLoading, client: client, holdsLoad: true)
        let session = makeSession(conversation, localModel: slow)

        session.send("一つ目")
        #expect(try await waitUntil { slow.clientCalls == 1 })
        session.stop()
        slow.currentReason = nil
        slow.holdsLoadForNextCall = false

        session.send("二つ目")
        #expect(try await waitUntil { client.requests.count == 1 })
        client.yield("途中")
        #expect(try await waitUntil { session.streamingText == "途中" })
        // The first send's load finishes late: it must not touch the second send.
        slow.releaseLoad()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.status == .running)
        #expect(session.streamingText == "途中")

        client.finish()
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 3 })
        #expect(session.turns.last == ChatTurn(role: .assistant, text: "途中"))
        #expect(client.requests.count == 1)
    }

    // The stopped send's late load must not clear the next (Claude) run's task: stop() still stops it.
    @Test func claudeRunAfterStoppedLoadStaysStoppable() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let slow = FakeLocalModel(reason: .modelLoading, client: GatedStreamClient(), holdsLoad: true)
        let claude = FakeLLMClient([
            .callTool(name: NoteToolName.save, arguments: #"{"text":"牛乳"}"#),
            .finish("保存しました")
        ])
        let session = makeSession(conversation, localModel: slow, resolve: { _, _ in .success(claude) })

        session.send("一つ目")
        #expect(try await waitUntil { slow.clientCalls == 1 })
        session.stop()

        settings.choice = .claude
        session.send("牛乳を覚えといて")
        #expect(try await waitUntil { broker.pending != nil })
        slow.releaseLoad()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.status == .running)

        session.stop()
        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(broker.pending == nil)
        #expect(try await notes.all().isEmpty)
    }

    // A memory warning drops the client before the screen calls stop(): the stream may end
    // normally, but the cut-off reply is never saved.
    @Test func unloadDuringStreamDoesNotSavePartial() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let local = FakeLocalModel(client: client)
        let session = makeSession(conversation, localModel: local)

        session.send("長い話をして")
        #expect(try await waitUntil { client.requests.count == 1 })
        client.yield("むかしむかし")
        #expect(try await waitUntil { session.streamingText == "むかしむかし" })
        local.currentReason = .unloadedForMemory
        client.finish()

        #expect(try await waitUntil { !session.isBusy })
        #expect(session.status == .failed(ModelUnavailableReason.unloadedForMemory.userMessage))
        #expect(session.lastFailureReason == .unloadedForMemory)
        #expect(session.streamingText == "")
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "長い話をして")])
    }

    @Test func notDownloadedSetsTypedReason() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let local = FakeLocalModel(reason: .modelNotDownloaded, client: client)
        let session = makeSession(conversation, localModel: local)

        session.send("やあ")
        #expect(session.lastFailureReason == .modelNotDownloaded)

        // The next send clears it.
        local.currentReason = nil
        session.send("もう一度")
        #expect(session.lastFailureReason == nil)
        #expect(try await waitUntil { client.requests.count == 1 })
        client.finish()
        #expect(try await waitUntil { session.status == .idle })
        #expect(session.lastFailureReason == nil)
    }

    @Test(arguments: [ModelUnavailableReason.modelNotDownloaded, .unloadedForMemory, .simulatorUnsupported])
    func unavailableModelShowsReasonWithoutLoading(_ reason: ModelUnavailableReason) async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let client = GatedStreamClient()
        let local = FakeLocalModel(reason: reason, client: client)
        let session = makeSession(conversation, localModel: local)

        session.send("やあ")

        #expect(session.status == .failed(reason.userMessage))
        // The user turn stays; the model is never loaded.
        #expect(session.turns == [ChatTurn(role: .user, text: "やあ")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "やあ")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(local.clientCalls == 0)
        #expect(client.requests.isEmpty)
    }

    @Test func clientThatCannotLoadShowsFixedText() async throws {
        let session = makeSession(try repository.create(choice: .mlxLocal), localModel: FakeLocalModel())

        session.send("やあ")

        #expect(try await waitUntil { session.status == .failed(MLXRuntime.loadFailedText) })
        #expect(session.turns.count == 1)
    }

    @Test func mlxLocalNeverTouchesResolverOrKey() async throws {
        let credentials = SpyCredentialStore(key: "test-key")
        let live = ChatSession.liveResolver(
            credentials: credentials, availability: FixedAvailability(reason: nil), settings: settings)
        let resolverCalls = LogLines()
        let client = GatedStreamClient()
        let session = makeSession(
            try repository.create(choice: .mlxLocal), localModel: FakeLocalModel(client: client),
            resolve: { choice, tools in
                resolverCalls.append(choice.rawValue)
                return live(choice, tools)
            })

        session.send("やあ")
        #expect(try await waitUntil { client.requests.count == 1 })
        client.yield("こんにちは")
        client.finish()
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })

        #expect(resolverCalls.entries.isEmpty)
        #expect(credentials.reads == 0)
    }

    @Test func mlxLocalLogsNoToolCallMetrics() async throws {
        // A reply that the Apple path would rescue as a save_note call.
        let reply = "あなたの名前をメモとして保存します。\n```json\n{\"text\": \"あなたの名前はケイタ\"}\n```"
        let lines = LogLines()
        let client = GatedStreamClient()
        let session = makeSession(
            try repository.create(choice: .mlxLocal), localModel: FakeLocalModel(client: client),
            log: { lines.append($0) })

        for (index, message) in ["私の名前はケイタ 覚えておいて", "覚えておいてね"].enumerated() {
            session.send(message)
            #expect(try await waitUntil { client.requests.count == index + 1 })
            client.yield(reply)
            client.finish()
            #expect(try await waitUntil { session.status == .idle && session.turns.last?.role == .assistant })
        }

        #expect(lines.entries.isEmpty)
        #expect(broker.pending == nil)
        #expect(try await notes.all().isEmpty)
        #expect(session.turns.last?.text == reply)
        #expect(!session.isToolSupportLimited)
    }
}
