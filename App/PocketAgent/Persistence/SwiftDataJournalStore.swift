import Foundation
import PocketAgentCore
import SwiftData

// RED stub: signatures only.
@ModelActor
actor SwiftDataJournalStore: JournalStore {
    func add(_ entry: NewJournalEntry) async throws -> JournalEntry {
        JournalEntry(createdAt: Date(), source: entry.source, origin: entry.origin, body: entry.body)
    }

    func all() async throws -> [JournalEntry] { [] }
    func search(_ query: String) async throws -> [JournalEntry] { [] }
    func entries(in interval: DateInterval) async throws -> [JournalEntry] { [] }
    func recent(limit: Int) async throws -> [JournalEntry] { [] }
    func entry(id: UUID) async throws -> JournalEntry? { nil }
    func delete(id: UUID) async throws -> Bool { true }
    func deleteAll() async throws {}
}
