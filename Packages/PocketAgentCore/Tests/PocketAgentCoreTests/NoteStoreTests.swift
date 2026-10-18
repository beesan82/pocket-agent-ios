import Foundation
import Testing
@testable import PocketAgentCore

struct NoteStoreTests {
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

    private func makeStore() -> InMemoryNoteStore {
        let clock = Clock()
        return InMemoryNoteStore(now: { clock.next() })
    }

    @Test func addedNotesListNewestFirst() async throws {
        let store = makeStore()
        _ = try await store.add("first")
        _ = try await store.add("second")
        let all = try await store.all()
        #expect(all.map(\.text) == ["second", "first"])
    }

    @Test func sameTimestampKeepsLaterAddedFirst() async throws {
        let store = InMemoryNoteStore(now: { Date(timeIntervalSince1970: 1) })
        _ = try await store.add("a")
        _ = try await store.add("b")
        #expect(try await store.all().map(\.text) == ["b", "a"])
    }

    @Test func searchMatchesAllWordsCaseInsensitive() async throws {
        #expect(NoteSearch.matches("土曜に牛乳", query: "牛乳 土曜"))
        #expect(!NoteSearch.matches("土曜に牛乳", query: "牛乳 日曜"))
        #expect(NoteSearch.matches("abc", query: "ABC"))
        #expect(NoteSearch.matches("土曜に牛乳", query: "牛乳\u{3000}土曜"))

        let store = makeStore()
        _ = try await store.add("土曜に牛乳")
        _ = try await store.add("日曜に卵")
        #expect(try await store.search("牛乳 土曜").map(\.text) == ["土曜に牛乳"])
        #expect(try await store.search("牛乳 日曜").isEmpty)
    }

    @Test func emptyQueryMatchesAll() async throws {
        #expect(NoteSearch.matches("anything", query: ""))
        #expect(NoteSearch.matches("anything", query: " \u{3000} "))
        let store = makeStore()
        _ = try await store.add("a")
        _ = try await store.add("b")
        #expect(try await store.search("").count == 2)
    }

    @Test func deleteRemovesNoteAndReturnsTrue() async throws {
        let store = makeStore()
        let note = try await store.add("a")
        #expect(try await store.note(id: note.id) == note)
        #expect(try await store.delete(id: note.id))
        #expect(try await store.note(id: note.id) == nil)
        #expect(try await store.all().isEmpty)
    }

    @Test func deleteReturnsFalseForUnknownId() async throws {
        let store = makeStore()
        _ = try await store.add("a")
        #expect(try await store.delete(id: UUID()) == false)
        #expect(try await store.all().count == 1)
    }

    @Test func deleteAllEmptiesStore() async throws {
        let store = makeStore()
        _ = try await store.add("a")
        _ = try await store.add("b")
        try await store.deleteAll()
        #expect(try await store.all().isEmpty)
    }
}
