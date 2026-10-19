import Foundation
import PocketAgentCore
import SwiftData

@ModelActor
actor SwiftDataNoteStore: NoteStore {
    func add(_ text: String) async throws -> Note {
        let record = NoteRecord(text: text, createdAt: Date())
        modelContext.insert(record)
        try modelContext.save()
        return Self.note(from: record)
    }

    func all() async throws -> [Note] {
        newestFirst(try modelContext.fetch(FetchDescriptor<NoteRecord>()))
    }

    /// Filters with `NoteSearch.matches` so results match the in-memory store exactly.
    func search(_ query: String) async throws -> [Note] {
        let records = try modelContext.fetch(FetchDescriptor<NoteRecord>())
        return newestFirst(records.filter { NoteSearch.matches($0.text, query: query) })
    }

    func note(id: UUID) async throws -> Note? {
        try fetchRecord(id: id).map(Self.note(from:))
    }

    func update(id: UUID, text: String) async throws -> Note? {
        guard let record = try fetchRecord(id: id) else { return nil }
        record.text = text
        try modelContext.save()
        return Self.note(from: record)
    }

    func delete(id: UUID) async throws -> Bool {
        guard let record = try fetchRecord(id: id) else { return false }
        modelContext.delete(record)
        try modelContext.save()
        return true
    }

    func deleteAll() async throws {
        try modelContext.delete(model: NoteRecord.self)
        try modelContext.save()
    }

    private func fetchRecord(id: UUID) throws -> NoteRecord? {
        var descriptor = FetchDescriptor<NoteRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Ties on createdAt keep the later-fetched (later-added) note first.
    private func newestFirst(_ records: [NoteRecord]) -> [Note] {
        records.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }
            .map { Self.note(from: $0.element) }
    }

    private static func note(from record: NoteRecord) -> Note {
        Note(id: record.id, text: record.text, createdAt: record.createdAt)
    }
}
