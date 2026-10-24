import Foundation
import PocketAgentCore
import SwiftData
import Testing
@testable import PocketAgent

@MainActor
struct PersistenceTests {
    // Kept as a property: a ModelContext crashes if its container is released.
    private let container: ModelContainer

    init() throws {
        container = try AppModelContainer.make(inMemory: true)
    }

    @Test func noteStoreCRUDAndSearch() async throws {
        let store = SwiftDataNoteStore(modelContainer: container)
        let a = try await store.add("牛乳を買う")
        try await Task.sleep(for: .milliseconds(20))
        let b = try await store.add("Buy milk and eggs")
        try await Task.sleep(for: .milliseconds(20))
        let c = try await store.add("会議メモ")

        #expect(try await store.all().map(\.id) == [c.id, b.id, a.id])
        #expect(try await store.search("milk eggs").map(\.id) == [b.id])
        #expect(try await store.search("牛乳").map(\.id) == [a.id])
        #expect(try await store.search("  ").count == 3)
        #expect(try await store.note(id: b.id)?.text == "Buy milk and eggs")
        #expect(try await store.delete(id: b.id))
        #expect(try await store.delete(id: b.id) == false)
        #expect(try await store.note(id: b.id) == nil)
        try await store.deleteAll()
        #expect(try await store.all().isEmpty)
    }

    @Test func turnsComeBackInOrder() throws {
        let context = container.mainContext
        let repo = ConversationRepository(context: context)
        let conversation = try repo.create(choice: .claude)
        try repo.append(ChatTurn(role: .user, text: "one"), to: conversation, choice: .claude)
        try repo.append(ChatTurn(role: .assistant, text: "two"), to: conversation, choice: .appleLocal)
        try repo.append(ChatTurn(role: .user, text: "three"), to: conversation, choice: .appleLocal)

        let turns = repo.turns(of: conversation)
        #expect(turns.map(\.text) == ["one", "two", "three"])
        #expect(turns.map(\.role) == [.user, .assistant, .user])
        #expect(conversation.modelChoiceRaw == "appleLocal")
    }

    @Test func titleIsFirstUserText30Chars() throws {
        let context = container.mainContext
        let repo = ConversationRepository(context: context)
        let conversation = try repo.create(choice: .claude)
        #expect(conversation.title == "新しい会話")
        try repo.append(ChatTurn(role: .assistant, text: "hello"), to: conversation, choice: .claude)
        #expect(conversation.title == "新しい会話")

        let long = "  " + String(repeating: "あ", count: 40) + "  "
        try repo.append(ChatTurn(role: .user, text: long), to: conversation, choice: .claude)
        #expect(conversation.title == String(repeating: "あ", count: 30))
        try repo.append(ChatTurn(role: .user, text: "second"), to: conversation, choice: .claude)
        #expect(conversation.title == String(repeating: "あ", count: 30))
    }

    @Test func allIsNewestUpdatedFirst() throws {
        let context = container.mainContext
        let repo = ConversationRepository(context: context)
        let first = try repo.create(choice: .claude)
        let second = try repo.create(choice: .claude)
        try repo.append(ChatTurn(role: .user, text: "bump"), to: first, choice: .claude)
        #expect(try repo.all().map(\.id) == [first.id, second.id])
    }

    @Test func deletingConversationRemovesTurns() throws {
        let context = container.mainContext
        let repo = ConversationRepository(context: context)
        let conversation = try repo.create(choice: .claude)
        try repo.append(ChatTurn(role: .user, text: "hi"), to: conversation, choice: .claude)
        try repo.append(ChatTurn(role: .assistant, text: "yo"), to: conversation, choice: .claude)
        #expect(try context.fetchCount(FetchDescriptor<TurnRecord>()) == 2)

        try repo.delete(conversation)
        #expect(try context.fetchCount(FetchDescriptor<TurnRecord>()) == 0)
        #expect(try repo.all().isEmpty)
    }

    @Test func eraseAllRemovesEverything() async throws {
        let context = container.mainContext
        let repo = ConversationRepository(context: context)
        let conversation = try repo.create(choice: .claude)
        try repo.append(ChatTurn(role: .user, text: "hi"), to: conversation, choice: .claude)
        let journal = SwiftDataJournalStore(modelContainer: container)
        let notes = JournalNoteStore(journal: journal)
        _ = try await notes.add("memo")
        let credentials = SpyCredentialStore(key: "test-key")
        let githubToken = SpyCredentialStore(key: "test-token-123")

        let base = FileManager.default.temporaryDirectory.appending(path: "reset-\(UUID())")
        let log = MeasurementLog(fileURL: base.appending(path: "log"))
        let drafts = JournalDraftStore(fileURL: base.appending(path: "draft"))
        defer { try? FileManager.default.removeItem(at: base) }
        log.append("音声テスト")
        try drafts.save(JournalDraft(source: .text, transcript: "下書き"))
        try await DataReset.eraseAll(context: context, journal: journal, credentials: credentials,
            githubToken: githubToken, measurementLog: log, drafts: drafts)

        #expect(try context.fetchCount(FetchDescriptor<ConversationRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TurnRecord>()) == 0)
        #expect(try await notes.all().isEmpty)
        #expect(credentials.deletes == 1)
        #expect(githubToken.deletes == 1)
        #expect(try githubToken.readAPIKey() == nil)
        #expect(try credentials.readAPIKey() == nil)
        #expect(MeasurementLog(fileURL: base.appending(path: "log")).entries.isEmpty)
        #expect(JournalDraftStore(fileURL: base.appending(path: "draft")).draft == nil)
    }

    @Test func failedLogDeletionStillAttemptsOtherDeletionsAndReportsFailure() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "reset-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let log = MeasurementLog(fileURL: base.appending(path: "log"),
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        let drafts = JournalDraftStore(fileURL: base.appending(path: "draft"))
        log.append("削除失敗するログ")
        try drafts.save(JournalDraft(source: .text, transcript: "削除する下書き"))
        let credentials = SpyCredentialStore(key: "test-key")
        let githubToken = SpyCredentialStore(key: "test-token")
        let journal = SwiftDataJournalStore(modelContainer: container)
        _ = try await journal.add(NewJournalEntry(source: .text, origin: .journal, body: "削除する日誌"))

        await #expect(throws: (any Error).self) {
            try await DataReset.eraseAll(context: container.mainContext, journal: journal,
                credentials: credentials, githubToken: githubToken, measurementLog: log, drafts: drafts)
        }
        #expect(try await journal.all().isEmpty)
        #expect(drafts.draft == nil)
        #expect(credentials.deletes == 1 && githubToken.deletes == 1)
        #expect(!log.entries.isEmpty)
    }

    @Test func noteUpdateReplacesText() async throws {
        let store = SwiftDataNoteStore(modelContainer: container)
        let a = try await store.add("旧")
        let updated = try #require(try await store.update(id: a.id, text: "新"))
        #expect(updated.id == a.id && updated.text == "新" && updated.createdAt == a.createdAt)
        #expect(try await store.all().map(\.text) == ["新"])
        #expect(try await store.update(id: UUID(), text: "x") == nil)
    }
}
