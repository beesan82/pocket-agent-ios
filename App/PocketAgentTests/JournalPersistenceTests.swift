import Foundation
import PocketAgentCore
import SwiftData
import Testing
@testable import PocketAgent

@MainActor
struct JournalPersistenceTests {
    // Kept as a property: a ModelContext crashes if its container is released.
    private let container: ModelContainer

    init() throws {
        container = try AppModelContainer.make(inMemory: true)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "JournalPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func insertRecord(_ body: String, at date: Date, sequence: Int, title: String? = nil) throws {
        let context = container.mainContext
        context.insert(JournalEntryRecord(
            createdAt: date, sequence: sequence, sourceRaw: "text", originRaw: "journal",
            body: body, title: title))
        try context.save()
    }

    @Test func crudAndNewestFirst() async throws {
        let store = SwiftDataJournalStore(modelContainer: container)
        // Added back to back: equal timestamps must still come back newest first.
        let a = try await store.add(NewJournalEntry(source: .voice, origin: .journal, body: "朝の散歩",
                                                    transcript: "あさのさんぽ", title: "散歩"))
        let b = try await store.add(NewJournalEntry(source: .text, origin: .noteTool, body: "牛乳を買う"))
        let c = try await store.add(NewJournalEntry(source: .text, origin: .journal, body: "会議"))

        #expect(try await store.all().map(\.id) == [c.id, b.id, a.id])
        #expect(try await store.recent(limit: 2).map(\.id) == [c.id, b.id])
        #expect(try await store.recent(limit: 0).isEmpty)

        let fetched = try #require(try await store.entry(id: a.id))
        #expect(fetched == a)
        #expect(fetched.source == .voice)
        #expect(fetched.origin == .journal)
        #expect(fetched.transcript == "あさのさんぽ")
        #expect(fetched.title == "散歩")
        #expect(try await store.entry(id: b.id)?.origin == .noteTool)

        #expect(try await store.delete(id: b.id))
        #expect(try await store.delete(id: b.id) == false)
        #expect(try await store.entry(id: b.id) == nil)
        #expect(try await store.all().map(\.id) == [c.id, a.id])

        try await store.deleteAll()
        #expect(try await store.all().isEmpty)
    }

    @Test func entriesInRange() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try insertRecord("before", at: base.addingTimeInterval(-1), sequence: 1)
        try insertRecord("start", at: base, sequence: 2)
        try insertRecord("tieOlder", at: base.addingTimeInterval(10), sequence: 3)
        try insertRecord("tieNewer", at: base.addingTimeInterval(10), sequence: 4)
        try insertRecord("end", at: base.addingTimeInterval(60), sequence: 5)

        let store = SwiftDataJournalStore(modelContainer: container)
        let range = try await store.entries(in: DateInterval(start: base, duration: 60))
        #expect(range.map(\.body) == ["tieNewer", "tieOlder", "start"])
        #expect(try await store.all().map(\.body) == ["end", "tieNewer", "tieOlder", "start", "before"])
    }

    @Test func searchMatchesTitle() async throws {
        let store = SwiftDataJournalStore(modelContainer: container)
        let titled = try await store.add(NewJournalEntry(
            source: .voice, origin: .journal, body: "今日は牛乳を買った", title: "買い物"))
        let other = try await store.add(NewJournalEntry(source: .text, origin: .journal, body: "会議メモ"))

        #expect(try await store.search("買い物").map(\.id) == [titled.id])
        #expect(try await store.search("牛乳").map(\.id) == [titled.id])
        #expect(try await store.search("会議").map(\.id) == [other.id])
        #expect(try await store.search("  ").map(\.id) == [other.id, titled.id])
    }

    @Test func searchFindsWordsOnlyInTranscript() async throws {
        let store = SwiftDataJournalStore(modelContainer: container)
        let summarized = try await store.add(NewJournalEntry(
            source: .voice, origin: .journal, body: "散歩した", transcript: "公園でコーヒーを飲んだ", title: "朝"))
        _ = try await store.add(NewJournalEntry(source: .text, origin: .journal, body: "会議"))
        #expect(try await store.search("コーヒー").map(\.id) == [summarized.id])
    }

    @Test func migrationCopiesAndDeletesOnce() async throws {
        let context = container.mainContext
        let defaults = try makeDefaults()
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_000_100)
        let older = NoteRecord(text: "古いメモ", createdAt: olderDate)
        let newer = NoteRecord(text: "新しいメモ", createdAt: newerDate)
        let noteIDs = [newer.id, older.id]
        context.insert(older)
        context.insert(newer)
        try context.save()

        try NoteMigration.migrateOnce(context: context, defaults: defaults)

        #expect(defaults.bool(forKey: "pocketagent.notesMigrated"))
        #expect(try context.fetchCount(FetchDescriptor<NoteRecord>()) == 0)
        let journal = SwiftDataJournalStore(modelContainer: container)
        let entries = try await journal.all()
        #expect(entries.map(\.body) == ["新しいメモ", "古いメモ"])
        #expect(entries.map(\.createdAt) == [newerDate, olderDate])
        #expect(entries.map(\.id) == noteIDs)
        #expect(entries.allSatisfy { $0.source == .text && $0.origin == .noteTool })
        let notes = JournalNoteStore(journal: journal)
        #expect(try await notes.all().map(\.text) == ["新しいメモ", "古いメモ"])

        // A second run does nothing, even if a note record shows up again.
        context.insert(NoteRecord(text: "後から", createdAt: Date()))
        try context.save()
        try NoteMigration.migrateOnce(context: context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<NoteRecord>()) == 1)
        #expect(try await journal.all().count == 2)
    }

    /// A save failure cannot be injected into SwiftData here, so this checks the other half
    /// of the contract: the flag alone decides whether migration runs, so a run that failed
    /// (flag left unset) is retried at the next launch.
    @Test func migrationFailureKeepsNotes() async throws {
        let context = container.mainContext
        let defaults = try makeDefaults()
        context.insert(NoteRecord(text: "残すメモ", createdAt: Date()))
        try context.save()

        defaults.set(true, forKey: "pocketagent.notesMigrated")
        try NoteMigration.migrateOnce(context: context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<NoteRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<JournalEntryRecord>()) == 0)

        defaults.removeObject(forKey: "pocketagent.notesMigrated")
        try NoteMigration.migrateOnce(context: context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<NoteRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<JournalEntryRecord>()) == 1)
        #expect(defaults.bool(forKey: "pocketagent.notesMigrated"))
    }

    /// A run whose first save (the copies) landed but whose delete did not: the retry updates the
    /// copy with the same id instead of adding a second entry.
    @Test func migrationRetryAfterPartialSaveUpserts() async throws {
        let context = container.mainContext
        let defaults = try makeDefaults()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let note = NoteRecord(text: "途中のメモ", createdAt: date)
        context.insert(note)
        context.insert(JournalEntryRecord(
            id: note.id, createdAt: date, sequence: 1, sourceRaw: "text", originRaw: "noteTool", body: "途中のメモ"))
        try context.save()

        try NoteMigration.migrateOnce(context: context, defaults: defaults)

        #expect(try context.fetchCount(FetchDescriptor<JournalEntryRecord>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<NoteRecord>()) == 0)
        #expect(defaults.bool(forKey: "pocketagent.notesMigrated"))
        let journal = SwiftDataJournalStore(modelContainer: container)
        #expect(try await journal.all().map(\.id) == [note.id])
    }

    @Test func eraseAllRemovesLeftoverNoteRecords() async throws {
        let context = container.mainContext
        let journal = SwiftDataJournalStore(modelContainer: container)
        context.insert(NoteRecord(text: "移行前のメモ", createdAt: Date()))
        try context.save()

        try await DataReset.eraseAll(
            context: context, journal: journal, credentials: SpyCredentialStore(key: "test-key"),
            githubToken: SpyCredentialStore(key: "test-token-123"),
            measurementLog: MeasurementLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "log-\(UUID())")),
            drafts: JournalDraftStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "draft-\(UUID())")))

        #expect(try context.fetchCount(FetchDescriptor<NoteRecord>()) == 0)
    }

    @Test func eraseAllRemovesJournal() async throws {
        let context = container.mainContext
        let journal = SwiftDataJournalStore(modelContainer: container)
        _ = try await journal.add(NewJournalEntry(source: .voice, origin: .journal, body: "日記"))
        _ = try await journal.add(NewJournalEntry(source: .text, origin: .noteTool, body: "メモ"))
        let credentials = SpyCredentialStore(key: "test-key")
        let githubToken = SpyCredentialStore(key: "test-token-123")
        #expect(try context.fetchCount(FetchDescriptor<JournalEntryRecord>()) == 2)

        try await DataReset.eraseAll(context: context, journal: journal, credentials: credentials, githubToken: githubToken,
            measurementLog: MeasurementLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "log-\(UUID())")),
            drafts: JournalDraftStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "draft-\(UUID())")))

        #expect(try await journal.all().isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<JournalEntryRecord>()) == 0)
        #expect(credentials.deletes == 1)
    }

    @Test func retryingCaptureIDReturnsExistingEntryWithoutOverwriting() async throws {
        let store = SwiftDataJournalStore(modelContainer: container)
        let id = UUID()
        _ = try await store.add(NewJournalEntry(source: .text, origin: .journal, body: "保存済み", id: id))
        let retried = try await store.add(NewJournalEntry(source: .text, origin: .journal, body: "再試行", id: id))
        #expect(retried.body == "保存済み")
        #expect(try await store.all().count == 1)
    }

    @Test func noteToolsSeeOnlyNoteToolEntries() async throws {
        let journal = SwiftDataJournalStore(modelContainer: container)
        let notes = JournalNoteStore(journal: journal)
        let diary = try await journal.add(NewJournalEntry(source: .voice, origin: .journal, body: "日記 牛乳"))
        let memo = try await notes.add("メモ 牛乳")

        #expect(try await notes.all().map(\.id) == [memo.id])
        #expect(try await notes.search("牛乳").map(\.id) == [memo.id])
        #expect(try await notes.note(id: diary.id) == nil)
        #expect(try await notes.delete(id: diary.id) == false)
        #expect(try await journal.entry(id: memo.id)?.origin == .noteTool)

        try await notes.deleteAll()
        #expect(try await journal.all().map(\.id) == [diary.id])
    }

    @Test func updateChangesBodyOnly() async throws {
        let store = SwiftDataJournalStore(modelContainer: container)
        let a = try await store.add(NewJournalEntry(source: .voice, origin: .journal, body: "朝", transcript: "あさ", title: "散歩"))
        let updated = try #require(try await store.update(id: a.id, body: "夜"))
        #expect(updated == JournalEntry(id: a.id, createdAt: a.createdAt, source: .voice, origin: .journal, body: "夜", transcript: "あさ", title: "散歩"))
        #expect(try await store.entry(id: a.id) == updated)
        #expect(try await store.update(id: UUID(), body: "x") == nil)
    }
}
