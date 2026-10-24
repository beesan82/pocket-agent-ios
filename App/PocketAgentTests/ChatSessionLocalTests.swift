import AgentRunKit
import Foundation
import PocketAgentCore
import PocketAgentRuntime
import SwiftData
import Testing
@testable import PocketAgent

/// On-device chat (Apple and the downloaded model): one fresh Foundation Models session per turn,
/// the note tools behind the approval sheet, user-only folding, rescue and the limited notice.
@MainActor
struct ChatSessionLocalTests {
    // Kept as a property: a ModelContext crashes if its container is released.
    private let container: ModelContainer
    private let repository: ConversationRepository
    private let settings: ModelSettings
    private let broker = ApprovalBroker()
    private let notes = InMemoryNoteStore()
    private let journal = InMemoryJournalStore()

    /// What the on-device model wrote on the iPhone instead of calling save_note.
    private static let rescuableSaveReply =
        "あなたの名前をメモとして保存します。\n```json\n{\"text\": \"あなたの名前はケイタ\"}\n```"

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
        notes customNotes: (any MemoryStore)? = nil,
        journal customJournal: (any JournalStore)? = nil,
        onDevice: any OnDeviceModelAccess,
        log: @escaping @MainActor (String) -> Void = { _ in },
        resolve: @escaping ClientResolver = { _ in
            Issue.record("on-device chat must never use the resolver")
            return .failure(.unavailable(.modelNotDownloaded))
        }
    ) -> ChatSession {
        ChatSession(
            conversation: conversation, repository: repository, notes: customNotes ?? notes,
            journal: customJournal ?? journal,
            settings: settings, broker: broker, resolve: resolve, onDevice: onDevice, log: log)
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

    // MARK: - Streaming and saving

    @Test func mlxLocalStreamsAndSavesReply() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let local = FakeOnDeviceModel(runner: runner)
        let session = makeSession(conversation, onDevice: local)

        session.send("やあ")

        #expect(try await waitUntil { runner.calls.count == 1 })
        #expect(session.status == .running)
        runner.yield("こん")
        #expect(try await waitUntil { session.streamingText == "こん" })
        // Nothing is saved while the reply is still streaming.
        #expect(session.turns == [ChatTurn(role: .user, text: "やあ")])
        runner.yield("にちは")
        #expect(try await waitUntil { session.streamingText == "こんにちは" })
        runner.finish()

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        let expected = [ChatTurn(role: .user, text: "やあ"), ChatTurn(role: .assistant, text: "こんにちは")]
        #expect(session.turns == expected)
        #expect(repository.turns(of: conversation) == expected)
        #expect(session.streamingText == "")
        #expect(local.runnerCalls == 1)
        #expect(runner.calls == [TurnCall(
            instructions: ConversationContext.onDeviceInstructions(memorySection: nil), prompt: "やあ")])
    }

    // Spike D3a: a fresh session per turn, earlier user turns folded in, assistant replies left out.
    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func secondTurnFoldsOnlyUserTurnsAndInjectsMemory(_ choice: ModelChoice) async throws {
        settings.choice = choice
        _ = try await notes.add("あなたの名前はケイタ")
        let runner = ScriptedTurnRunner([[.text("メモを保存しました: 牛乳")], [.text("ケイタさんです")]])
        let session = makeSession(try repository.create(choice: choice), onDevice: FakeOnDeviceModel(runner: runner))

        session.send("牛乳を覚えておいて")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        session.send("私の名前は？")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 4 })

        let section = ConversationContext.memorySection(memory: try await notes.allMemory(), limit: .appleLocal)
        let second = try #require(runner.calls.last)
        #expect(second.instructions == ConversationContext.onDeviceInstructions(memorySection: section))
        #expect(second.instructions.contains("あなたの名前はケイタ"))
        #expect(second.prompt == LocalAgentPrompt.fold(
            previous: [ChatTurn(role: .user, text: "牛乳を覚えておいて"),
                       ChatTurn(role: .assistant, text: "メモを保存しました: 牛乳")],
            current: "私の名前は？"))
        #expect(!second.prompt.contains("メモを保存しました"))
    }

    @Test func switchingFromClaudeFoldsOnlyUserTurns() async throws {
        settings.choice = .claude
        let claude = FakeLLMClient([.finish("Claude の答え")])
        let runner = ScriptedTurnRunner([[.text("端末内の答え")]])
        let session = makeSession(
            try repository.create(choice: .claude), onDevice: FakeOnDeviceModel(runner: runner),
            resolve: { _ in .success(claude) })

        session.send("一回目")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        settings.choice = .mlxLocal
        session.send("二回目")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 4 })

        let prompt = try #require(runner.calls.first?.prompt)
        #expect(prompt == LocalAgentPrompt.fold(
            previous: [ChatTurn(role: .user, text: "一回目"), ChatTurn(role: .assistant, text: "Claude の答え")],
            current: "二回目"))
        #expect(!prompt.contains("Claude の答え"))
    }

    // MARK: - Journal lookup (日誌に聞く merged into chat)

    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func onDeviceInstructionsIncludeJournalSection(_ choice: ModelChoice) async throws {
        settings.choice = choice
        _ = try await journal.add(NewJournalEntry(source: .text, origin: .journal, body: "ポチの散歩 朝7時"))
        let runner = ScriptedTurnRunner([[.text("朝7時です")]])
        let session = makeSession(try repository.create(choice: choice), onDevice: FakeOnDeviceModel(runner: runner))

        session.send("ポチの散歩はいつ？")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })

        let instructions = try #require(runner.calls.first?.instructions)
        #expect(instructions.contains(ConversationContext.journalLookupHeader))
        #expect(instructions.contains("ポチの散歩 朝7時"))
    }

    // A turn with matching entries drops the memory section's "recent journal" part; a turn
    // without keeps it.
    @Test func journalSectionReplacesRecentJournal() async throws {
        _ = try await journal.add(NewJournalEntry(source: .text, origin: .journal, body: "ポチの散歩 朝7時"))
        let runner = ScriptedTurnRunner([[.text("朝7時です")], [.text("こんにちは")]])
        let session = makeSession(
            try repository.create(choice: .mlxLocal), notes: JournalNoteStore(journal: journal),
            onDevice: FakeOnDeviceModel(runner: runner))

        session.send("ポチの散歩はいつ？")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        session.send("こんにちは")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 4 })

        let first = try #require(runner.calls.first?.instructions)
        #expect(first.contains(ConversationContext.journalLookupHeader))
        #expect(!first.contains(ConversationContext.journalHeader))
        let second = try #require(runner.calls.last?.instructions)
        #expect(!second.contains(ConversationContext.journalLookupHeader))
        #expect(second.contains(ConversationContext.journalHeader))
    }

    @Test func noJournalNoSection() async throws {
        let runner = ScriptedTurnRunner([[.text("こんにちは")]])
        let session = makeSession(try repository.create(choice: .mlxLocal), onDevice: FakeOnDeviceModel(runner: runner))

        session.send("先週の会議は？")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })

        #expect(runner.calls.first?.instructions == ConversationContext.onDeviceInstructions(memorySection: nil))
    }

    @Test func lookupFailureStillAnswers() async throws {
        let runner = ScriptedTurnRunner([[.text("こんにちは")]])
        let session = makeSession(
            try repository.create(choice: .mlxLocal), journal: ThrowingJournalStore(),
            onDevice: FakeOnDeviceModel(runner: runner))

        session.send("先週の会議は？")

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(runner.calls.first?.instructions.contains(ConversationContext.journalLookupHeader) == false)
    }

    // MARK: - Note tools

    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func nativeSaveAsksAndSaves(_ choice: ModelChoice) async throws {
        settings.choice = choice
        let lines = LogLines()
        let runner = ScriptedTurnRunner([[.callTool(NoteToolName.save, Self.json(["text": "ケイタ"])), .text("保存しました")]])
        let session = makeSession(
            try repository.create(choice: choice), onDevice: FakeOnDeviceModel(runner: runner),
            log: { lines.append($0) })

        session.send("私の名前はケイタ 覚えておいて")
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.approval.toolName == NoteToolName.save)
        #expect(broker.pending?.summary == "ケイタ")
        broker.answer(.approveOnce)

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(try await notes.all().map(\.text) == ["ケイタ"])
        #expect(lines.entries == ["toolcall.native model=\(choice.rawValue) tool=save_note"])
        #expect(!session.isToolSupportLimited)
    }

    @Test func deniedSaveDoesNotSave() async throws {
        let lines = LogLines()
        let runner = ScriptedTurnRunner([[.callTool(NoteToolName.save, Self.json(["text": "牛乳"]))]])
        let session = makeSession(
            try repository.create(choice: .mlxLocal), onDevice: FakeOnDeviceModel(runner: runner),
            log: { lines.append($0) })

        session.send("牛乳を覚えて")
        #expect(try await waitUntil { broker.pending != nil })
        broker.answer(.deny(reason: nil))

        // A second dialog (a rescue) would stop the wait with `pending` set.
        #expect(try await waitUntil { session.status != .running || broker.pending != nil })
        #expect(broker.pending == nil)
        #expect(session.status == .idle)
        #expect(session.turns.count == 2)
        #expect(try await notes.all().isEmpty)
        #expect(lines.entries == ["toolcall.native model=mlxLocal tool=save_note"])
    }

    // AT-08 on device: stopping while the approval sheet is open saves nothing.
    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func stopWhileApprovalPendingSavesNothing(_ choice: ModelChoice) async throws {
        settings.choice = choice
        let runner = ScriptedTurnRunner([[.callTool(NoteToolName.save, Self.json(["text": "牛乳"])), .text("保存しました")]])
        let conversation = try repository.create(choice: choice)
        let session = makeSession(conversation, onDevice: FakeOnDeviceModel(runner: runner))

        session.send("牛乳を覚えといて")
        #expect(try await waitUntil { broker.pending != nil })
        session.stop()

        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(broker.pending == nil)
        #expect(session.turns == [ChatTurn(role: .user, text: "牛乳を覚えといて")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "牛乳を覚えといて")])
        #expect(try await notes.all().isEmpty)
    }

    // Even if the framework runs the tool call outside the cancelled turn, stop() closes the sheet
    // and no note is saved, and a later tap on the closed sheet cannot save one either.
    @Test func stopDeniesApprovalEvenWhenToolIgnoresCancellation() async throws {
        let runner = ScriptedTurnRunner(
            [[.callTool(NoteToolName.save, Self.json(["text": "牛乳"])), .text("保存しました")]],
            toolsIgnoreCancellation: true)
        let conversation = try repository.create(choice: .mlxLocal)
        let session = makeSession(conversation, onDevice: FakeOnDeviceModel(runner: runner))

        session.send("牛乳を覚えといて")
        #expect(try await waitUntil { broker.pending != nil })
        session.stop()

        #expect(try await waitUntil { broker.pending == nil })
        broker.answer(.approveOnce)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await notes.all().isEmpty)
        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "牛乳を覚えといて")])
    }

    // Snapshots are cumulative but a model may rewrite its reply (e.g. after a tool call):
    // the saved reply is the last snapshot, never old + new.
    @Test func rewrittenReplyIsNotDuplicated() async throws {
        let runner = ScriptedTurnRunner([[.text("保存します。"), .rewrite("メモを保存しました。")]])
        let session = makeSession(try repository.create(choice: .mlxLocal), onDevice: FakeOnDeviceModel(runner: runner))

        session.send("牛乳を覚えて")

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(session.turns.last?.text == "メモを保存しました。")
    }

    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func rescuedJSONAsksAndSaves(_ choice: ModelChoice) async throws {
        settings.choice = choice
        let lines = LogLines()
        let runner = ScriptedTurnRunner([[.text(Self.rescuableSaveReply)]])
        let session = makeSession(
            try repository.create(choice: choice), onDevice: FakeOnDeviceModel(runner: runner),
            log: { lines.append($0) })

        session.send("私の名前はケイタ 覚えておいて")
        #expect(try await waitUntil { broker.pending != nil })
        #expect(broker.pending?.approval.toolName == NoteToolName.save)
        #expect(broker.pending?.summary == "あなたの名前はケイタ")
        broker.answer(.approveOnce)

        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(session.turns.last?.text == "あなたの名前をメモとして保存します。\n\nメモを保存しました")
        #expect(try await notes.all().map(\.text) == ["あなたの名前はケイタ"])
        #expect(lines.entries == ["toolcall.rescued model=\(choice.rawValue) tool=save_note"])
    }

    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func twoMissesMarkLimitedForBothLocalModels(_ choice: ModelChoice) async throws {
        settings.choice = choice
        let lines = LogLines()
        let runner = ScriptedTurnRunner([[.text("保存しました")], [.text("覚えました")], [.text("どうぞ")]])
        let claude = FakeLLMClient([.finish("こんにちは")])
        let session = makeSession(
            try repository.create(choice: choice), onDevice: FakeOnDeviceModel(runner: runner),
            log: { lines.append($0) }, resolve: { _ in .success(claude) })

        session.send("牛乳を覚えておいて")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })
        #expect(!session.isToolSupportLimited)
        session.send("歯医者をメモ")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 4 })

        #expect(session.isToolSupportLimited)
        let none = "toolcall.none model=\(choice.rawValue)"
        #expect(lines.entries == [none, none])

        // Never shown for Claude.
        settings.choice = .claude
        #expect(!session.isToolSupportLimited)
        session.send("こんにちは")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 6 })
        #expect(!session.isToolSupportLimited)
    }

    // MARK: - Availability and loading

    // AT-14: on-device chat never reads the Claude key nor resolves a Claude client.
    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func onDeviceNeverReadsKey(_ choice: ModelChoice) async throws {
        settings.choice = choice
        let credentials = SpyCredentialStore(key: "test-key")
        let live = ChatSession.liveResolver(
            credentials: credentials, availability: FixedAvailability(reason: nil), settings: settings)
        let resolverCalls = LogLines()
        let runner = ScriptedTurnRunner([[.text("こんにちは")]])
        let session = makeSession(
            try repository.create(choice: choice), onDevice: FakeOnDeviceModel(runner: runner),
            resolve: { choice in
                resolverCalls.append(choice.rawValue)
                return live(choice)
            })

        session.send("やあ")
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 2 })

        #expect(resolverCalls.entries.isEmpty)
        #expect(credentials.reads == 0)
    }

    // AT-03: an unavailable Apple model is reported and the user turn stays.
    @Test func unavailableAppleKeepsUserTurnAndShowsReason() async throws {
        settings.choice = .appleLocal
        let conversation = try repository.create(choice: .appleLocal)
        let local = FakeOnDeviceModel(
            runner: ScriptedTurnRunner([]), reasons: [.appleLocal: .appleIntelligenceNotEnabled])
        let session = makeSession(conversation, onDevice: local)

        session.send("予定覚えといて")

        #expect(session.status == .failed(ModelUnavailableReason.appleIntelligenceNotEnabled.userMessage))
        #expect(session.turns == [ChatTurn(role: .user, text: "予定覚えといて")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "予定覚えといて")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(local.runnerCalls == 0)
    }

    @Test func stopDoesNotSavePartial() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let session = makeSession(conversation, onDevice: FakeOnDeviceModel(runner: runner))

        session.send("長い話をして")
        #expect(try await waitUntil { runner.calls.count == 1 })
        runner.yield("むかしむかし")
        #expect(try await waitUntil { session.streamingText == "むかしむかし" })
        session.stop()

        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(session.turns == [ChatTurn(role: .user, text: "長い話をして")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "長い話をして")])
        #expect(session.streamingText == "")
        // Stopping the consumer ends the model's stream.
        #expect(try await waitUntil { runner.isTerminated })
    }

    @Test func stopWhileLoadingSavesNothing() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let local = FakeOnDeviceModel(runner: runner, reasons: [.mlxLocal: .modelLoading], holdsLoad: true)
        let session = makeSession(conversation, onDevice: local)

        session.send("やあ")
        #expect(session.status == .loadingModel)
        #expect(try await waitUntil { local.runnerCalls == 1 })
        // A second send while loading is ignored.
        session.send("もう一度")
        #expect(session.turns.count == 1)
        session.stop()
        local.releaseLoad()

        #expect(try await waitUntil { session.status == .failed(RunFailureText.stopped) })
        #expect(runner.calls.isEmpty)
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "やあ")])
    }

    // Loading cannot be cancelled: stop frees the session at once and the late load is ignored.
    @Test func stopDuringLoadReleasesBusyImmediately() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let local = FakeOnDeviceModel(runner: runner, reasons: [.mlxLocal: .modelLoading], holdsLoad: true)
        let session = makeSession(conversation, onDevice: local)

        session.send("やあ")
        #expect(try await waitUntil { local.runnerCalls == 1 })
        session.stop()

        #expect(session.status == .failed(RunFailureText.stopped))
        #expect(!session.isBusy)

        local.releaseLoad()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.status == .failed(RunFailureText.stopped))
        #expect(runner.calls.isEmpty)
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "やあ")])
    }

    // A send after a stop during loading is not disturbed by the stopped send's late completion.
    @Test func sendAfterStoppedLoadIsNotDisturbed() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let slow = FakeOnDeviceModel(runner: runner, reasons: [.mlxLocal: .modelLoading], holdsLoad: true)
        let session = makeSession(conversation, onDevice: slow)

        session.send("一つ目")
        #expect(try await waitUntil { slow.runnerCalls == 1 })
        session.stop()
        slow.reasons[.mlxLocal] = nil
        slow.holdsLoadForNextCall = false

        session.send("二つ目")
        #expect(try await waitUntil { runner.calls.count == 1 })
        runner.yield("途中")
        #expect(try await waitUntil { session.streamingText == "途中" })
        // The first send's load finishes late: it must not touch the second send.
        slow.releaseLoad()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.status == .running)
        #expect(session.streamingText == "途中")

        runner.finish()
        #expect(try await waitUntil { session.status == .idle && session.turns.count == 3 })
        #expect(session.turns.last == ChatTurn(role: .assistant, text: "途中"))
        #expect(runner.calls.count == 1)
    }

    // The stopped send's late load must not clear the next (Claude) run's task: stop() still stops it.
    @Test func claudeRunAfterStoppedLoadStaysStoppable() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let slow = FakeOnDeviceModel(runner: GatedTurnRunner(), reasons: [.mlxLocal: .modelLoading], holdsLoad: true)
        let claude = FakeLLMClient([
            .callTool(name: NoteToolName.save, arguments: #"{"text":"牛乳"}"#),
            .finish("保存しました")
        ])
        let session = makeSession(conversation, onDevice: slow, resolve: { _ in .success(claude) })

        session.send("一つ目")
        #expect(try await waitUntil { slow.runnerCalls == 1 })
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

    // A memory warning drops the model before the screen calls stop(): the stream may end
    // normally, but the cut-off reply is never saved.
    @Test func unloadDuringStreamDoesNotSavePartial() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let local = FakeOnDeviceModel(runner: runner)
        let session = makeSession(conversation, onDevice: local)

        session.send("長い話をして")
        #expect(try await waitUntil { runner.calls.count == 1 })
        runner.yield("むかしむかし")
        #expect(try await waitUntil { session.streamingText == "むかしむかし" })
        local.reasons[.mlxLocal] = .unloadedForMemory
        runner.finish()

        #expect(try await waitUntil { !session.isBusy })
        #expect(session.status == .failed(ModelUnavailableReason.unloadedForMemory.userMessage))
        #expect(session.lastFailureReason == .unloadedForMemory)
        #expect(session.streamingText == "")
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "長い話をして")])
    }

    @Test func notDownloadedSetsTypedReason() async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let local = FakeOnDeviceModel(runner: runner, reasons: [.mlxLocal: .modelNotDownloaded])
        let session = makeSession(conversation, onDevice: local)

        session.send("やあ")
        #expect(session.lastFailureReason == .modelNotDownloaded)

        // The next send clears it.
        local.reasons[.mlxLocal] = nil
        session.send("もう一度")
        #expect(session.lastFailureReason == nil)
        #expect(try await waitUntil { runner.calls.count == 1 })
        runner.finish()
        #expect(try await waitUntil { session.status == .idle })
        #expect(session.lastFailureReason == nil)
    }

    @Test(arguments: [ModelUnavailableReason.modelNotDownloaded, .unloadedForMemory, .simulatorUnsupported])
    func unavailableModelShowsReasonWithoutLoading(_ reason: ModelUnavailableReason) async throws {
        let conversation = try repository.create(choice: .mlxLocal)
        let runner = GatedTurnRunner()
        let local = FakeOnDeviceModel(runner: runner, reasons: [.mlxLocal: reason])
        let session = makeSession(conversation, onDevice: local)

        session.send("やあ")

        #expect(session.status == .failed(reason.userMessage))
        // The user turn stays; the model is never loaded.
        #expect(session.turns == [ChatTurn(role: .user, text: "やあ")])
        #expect(repository.turns(of: conversation) == [ChatTurn(role: .user, text: "やあ")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(local.runnerCalls == 0)
        #expect(runner.calls.isEmpty)
    }

    @Test func modelThatCannotLoadShowsFixedText() async throws {
        let session = makeSession(try repository.create(choice: .mlxLocal), onDevice: FakeOnDeviceModel())

        session.send("やあ")

        #expect(try await waitUntil { session.status == .failed(MLXRuntime.loadFailedText) })
        #expect(session.turns.count == 1)
    }
}
