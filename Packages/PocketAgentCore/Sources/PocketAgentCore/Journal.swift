import Foundation

/// One journal record: a voice or text entry, optionally with a summary title.
public struct JournalEntry: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable, Codable {
        case voice, text
    }

    /// Who saved the entry. Note tools only see `.noteTool` entries.
    public enum Origin: String, Sendable, Codable {
        case journal, noteTool
    }

    public let id: UUID
    public let createdAt: Date
    public let source: Source
    public let origin: Origin
    public let body: String
    public let transcript: String?
    public let title: String?

    public init(
        id: UUID = UUID(), createdAt: Date, source: Source, origin: Origin,
        body: String, transcript: String? = nil, title: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.origin = origin
        self.body = body
        self.transcript = transcript
        self.title = title
    }
}

/// Input for `JournalStore.add`; the store assigns createdAt and, by default, id.
/// A supplied id makes retrying the same capture idempotent.
public struct NewJournalEntry: Sendable {
    public let id: UUID?
    public let source: JournalEntry.Source
    public let origin: JournalEntry.Origin
    public let body: String
    public let transcript: String?
    public let title: String?

    public init(
        source: JournalEntry.Source, origin: JournalEntry.Origin, body: String,
        transcript: String? = nil, title: String? = nil, id: UUID? = nil
    ) {
        self.id = id
        self.source = source
        self.origin = origin
        self.body = body
        self.transcript = transcript
        self.title = title
    }
}

/// Storage for journal entries. Every list is newest first.
public protocol JournalStore: Sendable {
    func add(_ entry: NewJournalEntry) async throws -> JournalEntry
    func all() async throws -> [JournalEntry]
    func search(_ query: String) async throws -> [JournalEntry]
    /// Includes `interval.start`, excludes `interval.end`.
    func entries(in interval: DateInterval) async throws -> [JournalEntry]
    /// The newest `limit` entries; `limit <= 0` gives `[]`.
    func recent(limit: Int) async throws -> [JournalEntry]
    func entry(id: UUID) async throws -> JournalEntry?
    /// Replaces the body only; everything else is kept. Nil when there is no such entry.
    func update(id: UUID, body: String) async throws -> JournalEntry?
    func delete(id: UUID) async throws -> Bool
    func deleteAll() async throws
}

public actor InMemoryJournalStore: JournalStore {
    private var stored: [JournalEntry] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func add(_ entry: NewJournalEntry) async throws -> JournalEntry {
        if let id = entry.id, let existing = stored.first(where: { $0.id == id }) { return existing }
        let added = JournalEntry(
            id: entry.id ?? UUID(), createdAt: now(), source: entry.source, origin: entry.origin, body: entry.body,
            transcript: entry.transcript, title: entry.title
        )
        stored.append(added)
        return added
    }

    public func all() async throws -> [JournalEntry] { newestFirst(stored) }

    public func search(_ query: String) async throws -> [JournalEntry] {
        newestFirst(stored.filter {
            NoteSearch.matches($0.body + "\n" + ($0.title ?? "") + "\n" + ($0.transcript ?? ""), query: query)
        })
    }

    public func entries(in interval: DateInterval) async throws -> [JournalEntry] {
        newestFirst(stored.filter { $0.createdAt >= interval.start && $0.createdAt < interval.end })
    }

    public func recent(limit: Int) async throws -> [JournalEntry] {
        guard limit > 0 else { return [] }
        return Array(newestFirst(stored).prefix(limit))
    }

    public func entry(id: UUID) async throws -> JournalEntry? {
        stored.first { $0.id == id }
    }

    public func update(id: UUID, body: String) async throws -> JournalEntry? {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
        let old = stored[index]
        let updated = JournalEntry(
            id: old.id, createdAt: old.createdAt, source: old.source, origin: old.origin,
            body: body, transcript: old.transcript, title: old.title)
        stored[index] = updated
        return updated
    }

    public func delete(id: UUID) async throws -> Bool {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return false }
        stored.remove(at: index)
        return true
    }

    public func deleteAll() async throws {
        stored.removeAll()
    }

    /// Ties on createdAt keep the later-added entry first.
    private func newestFirst(_ list: [JournalEntry]) -> [JournalEntry] {
        list.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }
            .map(\.element)
    }
}

/// The `NoteStore` view of a journal, used by the Claude chat's note tools.
/// Its `NoteStore` methods only see entries those tools saved (`.noteTool`); its
/// `MemoryReading` side also exposes journal entries, read-only.
public struct JournalNoteStore: NoteStore, MemoryReading {
    private let journal: any JournalStore

    public init(journal: any JournalStore) {
        self.journal = journal
    }

    public func add(_ text: String) async throws -> Note {
        let entry = try await journal.add(NewJournalEntry(source: .text, origin: .noteTool, body: text))
        return Self.note(from: entry)
    }

    public func all() async throws -> [Note] {
        try await journal.all().filter(Self.isNoteTool).map(Self.note(from:))
    }

    public func search(_ query: String) async throws -> [Note] {
        try await journal.search(query).filter(Self.isNoteTool).map(Self.note(from:))
    }

    public func note(id: UUID) async throws -> Note? {
        guard let entry = try await journal.entry(id: id), Self.isNoteTool(entry) else { return nil }
        return Self.note(from: entry)
    }

    public func update(id: UUID, text: String) async throws -> Note? {
        guard try await note(id: id) != nil else { return nil }
        return try await journal.update(id: id, body: text).map(Self.note(from:))
    }

    public func allMemory() async throws -> [MemoryItem] {
        try await journal.all().map(Self.item(from:))
    }

    public func searchMemory(_ query: String) async throws -> [MemoryItem] {
        try await journal.search(query).map(Self.item(from:))
    }

    public func delete(id: UUID) async throws -> Bool {
        guard try await note(id: id) != nil else { return false }
        return try await journal.delete(id: id)
    }

    public func deleteAll() async throws {
        for entry in try await journal.all() where Self.isNoteTool(entry) {
            _ = try await journal.delete(id: entry.id)
        }
    }

    private static func isNoteTool(_ entry: JournalEntry) -> Bool { entry.origin == .noteTool }

    private static func item(from entry: JournalEntry) -> MemoryItem {
        MemoryItem(
            id: entry.id, kind: isNoteTool(entry) ? .note : .journal, createdAt: entry.createdAt,
            title: entry.title, text: entry.body)
    }

    private static func note(from entry: JournalEntry) -> Note {
        Note(id: entry.id, text: entry.body, createdAt: entry.createdAt)
    }
}
