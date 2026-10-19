import Foundation
import Testing
@testable import PocketAgentCore

struct JournalStoreTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var tick = 0
        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            tick += 1
            return Date(timeIntervalSince1970: Double(tick))
        }
    }

    private func makeStore() -> InMemoryJournalStore {
        let clock = Clock()
        return InMemoryJournalStore(now: { clock.next() })
    }

    private func new(_ body: String, title: String? = nil, origin: JournalEntry.Origin = .journal) -> NewJournalEntry {
        NewJournalEntry(source: .text, origin: origin, body: body, title: title)
    }

    @Test func addListsNewestFirst() async throws {
        let store = makeStore()
        _ = try await store.add(new("first"))
        _ = try await store.add(new("second"))
        #expect(try await store.all().map(\.body) == ["second", "first"])
    }

    @Test func addKeepsFields() async throws {
        let store = makeStore()
        let added = try await store.add(
            NewJournalEntry(source: .voice, origin: .journal, body: "b", transcript: "t", title: "ti")
        )
        #expect(added.source == .voice)
        #expect(added.origin == .journal)
        #expect(added.body == "b")
        #expect(added.transcript == "t")
        #expect(added.title == "ti")
        #expect(try await store.entry(id: added.id) == added)
    }

    @Test func sameTimestampKeepsLaterAddedFirst() async throws {
        let store = InMemoryJournalStore(now: { Date(timeIntervalSince1970: 1) })
        _ = try await store.add(new("a"))
        _ = try await store.add(new("b"))
        #expect(try await store.all().map(\.body) == ["b", "a"])
    }

    @Test func entriesInIntervalIsInclusiveStartExclusiveEnd() async throws {
        let store = makeStore()  // createdAt = 1, 2, 3, 4
        for body in ["a", "b", "c", "d"] { _ = try await store.add(new(body)) }
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 2), end: Date(timeIntervalSince1970: 4)
        )
        #expect(try await store.entries(in: interval).map(\.body) == ["c", "b"])
    }

    @Test func recentLimits() async throws {
        let store = makeStore()
        for body in ["a", "b", "c"] { _ = try await store.add(new(body)) }
        #expect(try await store.recent(limit: 2).map(\.body) == ["c", "b"])
        #expect(try await store.recent(limit: 10).map(\.body) == ["c", "b", "a"])
        #expect(try await store.recent(limit: 0).isEmpty)
        #expect(try await store.recent(limit: -1).isEmpty)
    }

    @Test func searchLooksAtTitleAndBody() async throws {
        let store = makeStore()
        _ = try await store.add(new("牛乳を買う", title: "買い物"))
        _ = try await store.add(new("散歩した", title: "日記"))
        #expect(try await store.search("牛乳").map(\.body) == ["牛乳を買う"])
        #expect(try await store.search("日記").map(\.body) == ["散歩した"])
        #expect(try await store.search("牛乳 買い物").count == 1)
        #expect(try await store.search("牛乳 日記").isEmpty)
        #expect(try await store.search("").count == 2)
    }

    @Test func deleteAndDeleteAll() async throws {
        let store = makeStore()
        let a = try await store.add(new("a"))
        _ = try await store.add(new("b"))
        #expect(try await store.delete(id: a.id))
        #expect(try await store.delete(id: a.id) == false)
        #expect(try await store.all().count == 1)
        try await store.deleteAll()
        #expect(try await store.all().isEmpty)
    }

    @Test func noteProjectionHidesJournalEntries() async throws {
        let journal = makeStore()
        let j1 = try await journal.add(new("j1"))
        _ = try await journal.add(new("j2"))
        let noteEntry = try await journal.add(new("n1", origin: .noteTool))
        let notes = JournalNoteStore(journal: journal)

        #expect(try await notes.all().map(\.text) == ["n1"])
        #expect(try await notes.search("j1").isEmpty)
        #expect(try await notes.note(id: j1.id) == nil)
        #expect(try await notes.note(id: noteEntry.id)?.text == "n1")
        #expect(try await notes.delete(id: j1.id) == false)
        #expect(try await journal.entry(id: j1.id) != nil)

        try await notes.deleteAll()
        #expect(try await notes.all().isEmpty)
        #expect(try await journal.all().map(\.body) == ["j2", "j1"])
    }

    @Test func noteProjectionAddsAsNoteTool() async throws {
        let journal = makeStore()
        let notes = JournalNoteStore(journal: journal)
        let note = try await notes.add("牛乳")

        #expect(note.text == "牛乳")
        let entry = try #require(try await journal.entry(id: note.id))
        #expect(entry.origin == .noteTool)
        #expect(entry.source == .text)
        #expect(entry.body == "牛乳")
        #expect(entry.createdAt == note.createdAt)
        #expect(try await notes.delete(id: note.id))
        #expect(try await journal.all().isEmpty)
    }

    @Test func updateKeepsEverythingButBody() async throws {
        let store = makeStore()
        let added = try await store.add(NewJournalEntry(source: .voice, origin: .journal, body: "b", transcript: "t", title: "ti"))
        let updated = try #require(try await store.update(id: added.id, body: "b2"))
        #expect(updated == JournalEntry(id: added.id, createdAt: added.createdAt, source: .voice, origin: .journal, body: "b2", transcript: "t", title: "ti"))
        #expect(try await store.entry(id: added.id) == updated)
        #expect(try await store.update(id: UUID(), body: "x") == nil)
    }

    @Test func noteProjectionUpdatesOnlyNoteToolEntries() async throws {
        let journal = makeStore()
        let diary = try await journal.add(new("日誌", origin: .journal))
        let notes = JournalNoteStore(journal: journal)
        let note = try await notes.add("メモ")
        #expect(try await notes.update(id: diary.id, text: "改ざん") == nil)
        #expect(try await journal.entry(id: diary.id)?.body == "日誌")
        #expect(try await notes.update(id: note.id, text: "メモ2")?.text == "メモ2")
    }

    @Test func noteProjectionMemoryIncludesJournalWithKindAndTitle() async throws {
        let journal = makeStore()
        _ = try await journal.add(new("朝の散歩", title: "散歩", origin: .journal))
        let notes = JournalNoteStore(journal: journal)
        _ = try await notes.add("牛乳")
        let memory = try await notes.allMemory()
        #expect(memory.map(\.kind) == [.note, .journal])
        #expect(memory.map(\.text) == ["牛乳", "朝の散歩"])
        #expect(memory.map(\.title) == [nil, "散歩"])
        #expect(try await notes.searchMemory("散歩").map(\.kind) == [.journal])
        #expect(try await notes.all().map(\.text) == ["牛乳"])
    }
}
