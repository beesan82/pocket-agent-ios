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

/// Input for `JournalStore.add`; the store assigns id and createdAt.
public struct NewJournalEntry: Sendable {
    public let source: JournalEntry.Source
    public let origin: JournalEntry.Origin
    public let body: String
    public let transcript: String?
    public let title: String?

    public init(
        source: JournalEntry.Source, origin: JournalEntry.Origin, body: String,
        transcript: String? = nil, title: String? = nil
    ) {
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
    func delete(id: UUID) async throws -> Bool
    func deleteAll() async throws
}

public actor InMemoryJournalStore: JournalStore {
    private var entries: [JournalEntry] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func add(_ entry: NewJournalEntry) async throws -> JournalEntry {
        JournalEntry(createdAt: now(), source: entry.source, origin: entry.origin, body: "")
    }

    public func all() async throws -> [JournalEntry] { [] }

    public func search(_ query: String) async throws -> [JournalEntry] { [] }

    public func entries(in interval: DateInterval) async throws -> [JournalEntry] { [] }

    public func recent(limit: Int) async throws -> [JournalEntry] { [] }

    public func entry(id: UUID) async throws -> JournalEntry? { nil }

    public func delete(id: UUID) async throws -> Bool { false }

    public func deleteAll() async throws {}
}

/// The `NoteStore` view of a journal, used by the Claude chat's note tools.
/// It only sees entries those tools saved (`.noteTool`), never journal entries.
public struct JournalNoteStore: NoteStore {
    private let journal: any JournalStore

    public init(journal: any JournalStore) {
        self.journal = journal
    }

    public func add(_ text: String) async throws -> Note {
        Note(text: "", createdAt: Date(timeIntervalSince1970: 0))
    }

    public func all() async throws -> [Note] { [] }

    public func search(_ query: String) async throws -> [Note] { [] }

    public func note(id: UUID) async throws -> Note? { nil }

    public func delete(id: UUID) async throws -> Bool { false }

    public func deleteAll() async throws {}
}
