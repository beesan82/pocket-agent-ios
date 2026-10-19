import Foundation
import PocketAgentCore
import SwiftData

/// Journal entries in SwiftData. Records stay inside the actor; callers get `JournalEntry` values.
@ModelActor
actor SwiftDataJournalStore: JournalStore {
    func add(_ entry: NewJournalEntry) async throws -> JournalEntry {
        let sequence = try Self.nextSequence(in: modelContext)
        let record = JournalEntryRecord(
            createdAt: Date(), sequence: sequence,
            sourceRaw: entry.source.rawValue, originRaw: entry.origin.rawValue,
            body: entry.body, transcript: entry.transcript, title: entry.title)
        modelContext.insert(record)
        try save()
        return JournalEntry(
            id: record.id, createdAt: record.createdAt, source: entry.source, origin: entry.origin,
            body: entry.body, transcript: entry.transcript, title: entry.title)
    }

    func all() async throws -> [JournalEntry] {
        try fetch(FetchDescriptor(sortBy: Self.newestFirst))
    }

    /// Filters with `NoteSearch.matches` so results match the in-memory store exactly.
    func search(_ query: String) async throws -> [JournalEntry] {
        try await all().filter { NoteSearch.matches($0.body + "\n" + ($0.title ?? ""), query: query) }
    }

    func entries(in interval: DateInterval) async throws -> [JournalEntry] {
        let start = interval.start
        let end = interval.end
        return try fetch(FetchDescriptor(
            predicate: #Predicate { $0.createdAt >= start && $0.createdAt < end },
            sortBy: Self.newestFirst))
    }

    func recent(limit: Int) async throws -> [JournalEntry] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<JournalEntryRecord>(sortBy: Self.newestFirst)
        descriptor.fetchLimit = limit
        return try fetch(descriptor)
    }

    func entry(id: UUID) async throws -> JournalEntry? {
        try fetchRecord(id: id).flatMap(Self.entry(from:))
    }

    func update(id: UUID, body: String) async throws -> JournalEntry? {
        guard let record = try fetchRecord(id: id) else { return nil }
        record.body = body
        try save()
        return Self.entry(from: record)
    }

    func delete(id: UUID) async throws -> Bool {
        guard let record = try fetchRecord(id: id) else { return false }
        modelContext.delete(record)
        try save()
        return true
    }

    func deleteAll() async throws {
        try modelContext.delete(model: JournalEntryRecord.self)
        try save()
    }

    /// Newest first; `sequence` orders entries that share a timestamp.
    private static var newestFirst: [SortDescriptor<JournalEntryRecord>] {
        [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.sequence, order: .reverse)]
    }

    private func fetch(_ descriptor: FetchDescriptor<JournalEntryRecord>) throws -> [JournalEntry] {
        try modelContext.fetch(descriptor).compactMap(Self.entry(from:))
    }

    private func fetchRecord(id: UUID) throws -> JournalEntryRecord? {
        var descriptor = FetchDescriptor<JournalEntryRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// On failure, discards the pending changes so a later save cannot commit them.
    private func save() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// One more than the largest stored sequence (1 for an empty journal).
    static func nextSequence(in context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<JournalEntryRecord>(
            sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try context.fetch(descriptor).first?.sequence ?? 0) + 1
    }

    /// Nil for a record whose source or origin this build does not know.
    private static func entry(from record: JournalEntryRecord) -> JournalEntry? {
        guard let source = JournalEntry.Source(rawValue: record.sourceRaw),
              let origin = JournalEntry.Origin(rawValue: record.originRaw)
        else { return nil }
        return JournalEntry(
            id: record.id, createdAt: record.createdAt, source: source, origin: origin,
            body: record.body, transcript: record.transcript, title: record.title)
    }
}
