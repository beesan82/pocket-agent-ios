import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

private struct NoteJSON: Decodable {
    let id: String
    let createdAt: String
    let kind: String
    let title: String?
    let text: String
}

private struct NoteListJSON: Decodable {
    let notes: [NoteJSON]
    let truncated: Bool
}

private func tool(_ name: String, in tools: [RegisteredTool<EmptyContext>]) throws -> any AnyTool<EmptyContext> {
    try #require(tools.first { $0.tool.name == name }).tool
}

private func run(_ name: String, _ arguments: String, in tools: [RegisteredTool<EmptyContext>]) async throws -> ToolResult {
    try await tool(name, in: tools).execute(arguments: Data(arguments.utf8), context: EmptyContext())
}

struct NoteToolsTests {
    @Test func toolShape() throws {
        let tools = NoteTools.make(store: InMemoryNoteStore(), limit: .claude)
        #expect(tools.map(\.tool.name) == ["save_note", "edit_note", "list_notes", "search_notes", "delete_note"])
        #expect(tools.map(\.risk) == [.appInternalWrite, .appInternalWrite, .readOnly, .readOnly, .appInternalDelete])
        #expect(tools.map(\.tool.isReadOnly) == [false, false, true, true, false])
        #expect(tools.allSatisfy { !$0.tool.description.isEmpty })
    }

    @Test func saveRequiresApprovalAndStores() async throws {
        let store = InMemoryNoteStore()
        let asked = Log<PendingApproval>()
        let client = ScriptedLLMClient([
            .callTool(name: "save_note", arguments: #"{"text":"  明日 歯医者 15時  "}"#),
            .finish("保存しました")
        ])
        let runner = AgentRunner(client: client, tools: NoteTools.make(store: store, limit: .claude))

        let outcome = try await runner.run("明日の歯医者を覚えて", context: EmptyContext()) { request in
            await asked.append(request)
            return .approveOnce
        }

        #expect(outcome == .completed("保存しました"))
        let requests = await asked.entries
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "save_note")
        #expect(requests.first?.risk == .appInternalWrite)
        let notes = try await store.all()
        #expect(notes.map(\.text) == ["明日 歯医者 15時"])
    }

    // AT-05
    @Test func deniedSaveStoresNothing() async throws {
        let store = InMemoryNoteStore()
        let client = ScriptedLLMClient([
            .callTool(name: "save_note", arguments: #"{"text":"秘密"}"#),
            .finish("やめました")
        ])
        let runner = AgentRunner(client: client, tools: NoteTools.make(store: store, limit: .claude))

        let outcome = try await runner.run("覚えて", context: EmptyContext()) { _ in .deny(reason: nil) }

        #expect(outcome == .completed("やめました"))
        #expect(try await store.all().isEmpty)
    }

    @Test func savedResultContainsIdAndTrimmedText() async throws {
        let store = InMemoryNoteStore()
        let tools = NoteTools.make(store: store, limit: .claude)

        let result = try await run("save_note", #"{"text":" 牛乳 "}"#, in: tools)

        #expect(!result.isError)
        let saved = try #require(try await store.all().first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: String])
        #expect(json["id"] == saved.id.uuidString)
        #expect(json["text"] == "牛乳")
    }

    @Test func maxLengthIsAccepted() async throws {
        let store = InMemoryNoteStore()
        let tools = NoteTools.make(store: store, limit: .claude)
        let text = String(repeating: "あ", count: NoteTools.maxNoteLength)

        let result = try await run("save_note", #"{"text":"\#(text)"}"#, in: tools)

        #expect(!result.isError)
        #expect(try await store.all().count == 1)
    }

    @Test func invalidArgumentsNeverTouchStore() async throws {
        let store = InMemoryNoteStore()
        let existing = try await store.add("既存")
        let tools = NoteTools.make(store: store, limit: .claude)
        let tooLong = String(repeating: "あ", count: NoteTools.maxNoteLength + 1)

        let cases: [(String, String)] = [
            ("save_note", #"{"text":""}"#),
            ("save_note", #"{"text":"   \n "}"#),
            ("save_note", #"{"text":"\#(tooLong)"}"#),
            ("save_note", "{not json"),
            ("save_note", "{}"),
            ("search_notes", "{}"),
            ("search_notes", "{broken"),
            ("delete_note", #"{"id":"not-a-uuid"}"#),
            ("delete_note", "{}"),
            ("delete_note", "[[[")
        ]
        for (name, arguments) in cases {
            let result = try await run(name, arguments, in: tools)
            #expect(result.isError, "\(name) \(arguments.prefix(30))")
            #expect(!result.content.contains("not-a-uuid"))
        }

        #expect(try await store.all() == [existing])
    }

    @Test func editRequiresApprovalAndUpdates() async throws {
        let store = InMemoryNoteStore()
        let note = try await store.add("古い")
        let asked = Log<PendingApproval>()
        let client = ScriptedLLMClient([
            .callTool(name: "edit_note", arguments: #"{"id":"\#(note.id.uuidString)","text":" 新しい "}"#),
            .finish("直しました")
        ])
        let runner = AgentRunner(client: client, tools: NoteTools.make(store: store, limit: .claude))

        let outcome = try await runner.run("直して", context: EmptyContext()) { request in
            await asked.append(request)
            return .approveOnce
        }

        #expect(outcome == .completed("直しました"))
        #expect(await asked.entries.map(\.toolName) == ["edit_note"])
        #expect(try await store.all().map(\.text) == ["新しい"])
    }

    @Test func editRejectsBadArgumentsAndUnknownIds() async throws {
        let store = InMemoryNoteStore()
        let existing = try await store.add("既存")
        let tools = NoteTools.make(store: store, limit: .claude)
        let tooLong = String(repeating: "あ", count: NoteTools.maxNoteLength + 1)
        let id = existing.id.uuidString

        let cases = [
            "{}", "{broken", #"{"id":"\#(id)","text":"   "}"#, #"{"id":"\#(id)","text":"\#(tooLong)"}"#,
            #"{"id":"not-a-uuid","text":"x"}"#, #"{"id":"\#(id)"}"#
        ]
        for arguments in cases {
            let result = try await run("edit_note", arguments, in: tools)
            #expect(result.isError, "\(arguments.prefix(30))")
        }
        let unknown = try await run("edit_note", #"{"id":"\#(UUID().uuidString)","text":"x"}"#, in: tools)
        #expect(unknown == .error("該当するメモがありません"))
        #expect(try await store.all() == [existing])
    }

    @Test func editAndDeleteRefuseJournalEntries() async throws {
        let journal = InMemoryJournalStore()
        let diary = try await journal.add(NewJournalEntry(source: .text, origin: .journal, body: "日誌"))
        let tools = NoteTools.make(store: JournalNoteStore(journal: journal), limit: .claude)
        for name in ["edit_note", "delete_note"] {
            let result = try await run(name, #"{"id":"\#(diary.id.uuidString)","text":"x"}"#, in: tools)
            #expect(result.isError && result.content.contains("記録タブ"), "\(name)")
        }
        #expect(try await journal.entry(id: diary.id)?.body == "日誌")
    }

    @Test func listAndSearchIncludeJournalWithKind() async throws {
        let journal = InMemoryJournalStore()
        _ = try await journal.add(NewJournalEntry(source: .voice, origin: .journal, body: "朝の散歩", title: "散歩"))
        let store = JournalNoteStore(journal: journal)
        _ = try await store.add("牛乳")
        let tools = NoteTools.make(store: store, limit: .claude)

        let list = try JSONDecoder().decode(
            NoteListJSON.self, from: Data(try await run("list_notes", "{}", in: tools).content.utf8))
        #expect(Set(list.notes.map(\.kind)) == ["note", "journal"])
        #expect(list.notes.first { $0.kind == "journal" }?.title == "散歩")
        #expect(list.notes.first { $0.kind == "note" }?.title == nil)
        let found = try JSONDecoder().decode(
            NoteListJSON.self, from: Data(try await run("search_notes", #"{"query":"散歩"}"#, in: tools).content.utf8))
        #expect(found.notes.map(\.kind) == ["journal"])
    }

    @Test func journalItemsAreCappedAt400ButNotesAreNot() async throws {
        let journal = InMemoryJournalStore()
        _ = try await journal.add(NewJournalEntry(source: .text, origin: .journal, body: String(repeating: "あ", count: 500)))
        let tools = NoteTools.make(store: JournalNoteStore(journal: journal), limit: .claude)
        let list = try JSONDecoder().decode(
            NoteListJSON.self, from: Data(try await run("list_notes", "{}", in: tools).content.utf8))
        #expect(list.notes.first?.text.count == 400)
        #expect(list.truncated)

        let store = InMemoryNoteStore()
        _ = try await store.add(String(repeating: "あ", count: 500))
        let noteList = try JSONDecoder().decode(
            NoteListJSON.self,
            from: Data(try await run("list_notes", "{}", in: NoteTools.make(store: store, limit: .claude)).content.utf8))
        #expect(noteList.notes.first?.text.count == 500)
        #expect(!noteList.truncated)
    }

    @Test func listRespectsLimit() async throws {
        let store = InMemoryNoteStore()
        for index in 0 ..< 12 {
            _ = try await store.add(String(repeating: "あ", count: 300) + "\(index)")
        }
        let tools = NoteTools.make(store: store, limit: .appleLocal)

        let result = try await run("list_notes", "{}", in: tools)

        #expect(!result.isError)
        let list = try JSONDecoder().decode(NoteListJSON.self, from: Data(result.content.utf8))
        #expect(list.notes.count == 10)
        #expect(list.notes.allSatisfy { $0.text.count == 200 })
        #expect(list.truncated)
    }

    @Test func listIsNotTruncatedWithinLimits() async throws {
        let store = InMemoryNoteStore(now: { Date(timeIntervalSince1970: 0) })
        _ = try await store.add("短い")
        let tools = NoteTools.make(store: store, limit: .appleLocal)

        let result = try await run("list_notes", "{}", in: tools)

        let list = try JSONDecoder().decode(NoteListJSON.self, from: Data(result.content.utf8))
        #expect(list.notes.map(\.text) == ["短い"])
        #expect(list.notes.first?.createdAt == "1970-01-01T00:00:00Z")
        #expect(!list.truncated)
    }

    @Test func searchFiltersAndDoesNotTouchStore() async throws {
        let store = InMemoryNoteStore()
        _ = try await store.add("歯医者 15時")
        _ = try await store.add("牛乳を買う")
        let tools = NoteTools.make(store: store, limit: .claude)

        let result = try await run("search_notes", #"{"query":"歯医者"}"#, in: tools)

        let list = try JSONDecoder().decode(NoteListJSON.self, from: Data(result.content.utf8))
        #expect(list.notes.map(\.text) == ["歯医者 15時"])
        #expect(!list.truncated)
        #expect(try await store.all().count == 2)
    }

    @Test func deleteAsksEveryTimeOnBothPaths() async throws {
        // Claude path
        let store = InMemoryNoteStore()
        let first = try await store.add("一")
        let second = try await store.add("二")
        let asked = Log<PendingApproval>()
        let approvals = ConversationApprovals()
        let handler = approvals.handler { request in
            await asked.append(request)
            return .approveForSession
        }
        let client = ScriptedLLMClient([
            .callTool(name: "delete_note", arguments: #"{"id":"\#(first.id.uuidString)"}"#),
            .callTool(name: "delete_note", arguments: #"{"id":"\#(second.id.uuidString)"}"#),
            .finish("done")
        ])
        let runner = AgentRunner(client: client, tools: NoteTools.make(store: store, limit: .claude))
        let outcome = try await runner.run("消して", context: EmptyContext(), approval: handler)
        #expect(outcome == .completed("done"))
        #expect(await asked.entries.count == 2)
        #expect(try await store.all().isEmpty)

        // Gate path (on-device)
        let gateStore = InMemoryNoteStore()
        let gateFirst = try await gateStore.add("一")
        let gateSecond = try await gateStore.add("二")
        let gateAsked = Log<PendingApproval>()
        let gateApprovals = ConversationApprovals()
        let gateHandler = gateApprovals.handler { request in
            await gateAsked.append(request)
            return .approveForSession
        }
        let gated = ToolApprovalGate.wrap(NoteTools.make(store: gateStore, limit: .appleLocal), approval: gateHandler)
        let delete = try #require(gated.first { $0.name == "delete_note" })
        for note in [gateFirst, gateSecond] {
            let result = try await delete.execute(
                arguments: Data(#"{"id":"\#(note.id.uuidString)"}"#.utf8),
                context: EmptyContext()
            )
            #expect(result.content == #"{"deleted":true}"#)
        }
        #expect(await gateAsked.entries.count == 2)
        #expect(try await gateStore.all().isEmpty)
    }

    @Test func injectedDeleteIsBlockedByDenial() async throws {
        let store = InMemoryNoteStore()
        let note = try await store.add("大事なメモ")
        _ = try await store.add("もう一つ")
        let asked = Log<PendingApproval>()
        let client = ScriptedLLMClient([
            .callTool(name: "delete_note", arguments: #"{"id":"\#(note.id.uuidString)"}"#),
            .finish("消せませんでした")
        ])
        let runner = AgentRunner(client: client, tools: NoteTools.make(store: store, limit: .claude))

        let outcome = try await runner.run("メモを全部消して", context: EmptyContext()) { request in
            await asked.append(request)
            return .deny(reason: nil)
        }

        #expect(outcome == .completed("消せませんでした"))
        #expect(await asked.entries.count == 1)
        #expect(try await store.all().count == 2)
    }

    // AT-08
    @Test(.timeLimit(.minutes(1)))
    func cancelWhileAwaitingApprovalSavesNothing() async throws {
        let store = InMemoryNoteStore()
        let client = ScriptedLLMClient([
            .callTool(name: "save_note", arguments: #"{"text":"保存されないはず"}"#),
            .finish("done")
        ])
        let runner = AgentRunner(client: client, tools: NoteTools.make(store: store, limit: .claude))
        let (dialogShown, signal) = AsyncStream.makeStream(of: Void.self)

        let task = Task {
            try await runner.run("覚えて", context: EmptyContext()) { _ in
                signal.yield()
                try? await Task.sleep(for: .seconds(30))
                return .approveOnce
            }
        }
        var iterator = dialogShown.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        #expect(try await task.value == .cancelled)
        #expect(try await store.all().isEmpty)
    }

    @Test func unknownIdIsReportedNotThrown() async throws {
        let store = InMemoryNoteStore()
        _ = try await store.add("残る")
        let tools = NoteTools.make(store: store, limit: .claude)

        let result = try await run("delete_note", #"{"id":"\#(UUID().uuidString)"}"#, in: tools)

        #expect(result == .error("該当するメモがありません"))
        #expect(try await store.all().count == 1)
    }

    @Test func storeErrorsBecomeToolErrors() async throws {
        let tools = NoteTools.make(store: FailingStore(), limit: .claude)
        let calls = [
            ("save_note", #"{"text":"a"}"#),
            ("edit_note", #"{"id":"\#(UUID().uuidString)","text":"a"}"#),
            ("list_notes", "{}"),
            ("search_notes", #"{"query":"a"}"#),
            ("delete_note", #"{"id":"\#(UUID().uuidString)"}"#)
        ]
        for (name, arguments) in calls {
            let result = try await run(name, arguments, in: tools)
            #expect(result.isError, "\(name)")
            #expect(!result.content.contains("SECRET-DETAIL"))
        }
    }
}

private struct FailingStore: MemoryStore {
    struct Failure: Error, CustomStringConvertible { let description = "SECRET-DETAIL" }

    func add(_: String) async throws -> Note { throw Failure() }
    func all() async throws -> [Note] { throw Failure() }
    func search(_: String) async throws -> [Note] { throw Failure() }
    func note(id _: UUID) async throws -> Note? { throw Failure() }
    func delete(id _: UUID) async throws -> Bool { throw Failure() }
    func update(id _: UUID, text _: String) async throws -> Note? { throw Failure() }
    func deleteAll() async throws { throw Failure() }
    func allMemory() async throws -> [MemoryItem] { throw Failure() }
    func searchMemory(_: String) async throws -> [MemoryItem] { throw Failure() }
}
