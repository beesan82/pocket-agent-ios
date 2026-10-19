import Foundation

public struct Note: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// A note or journal entry as the chat's memory sees it.
public struct MemoryItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case note, journal }

    public let id: UUID
    public let kind: Kind
    public let createdAt: Date
    public let title: String?
    public let text: String

    public init(id: UUID, kind: Kind, createdAt: Date, title: String? = nil, text: String) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.title = title
        self.text = text
    }
}

/// What the chat may "remember": notes and journal entries, newest first.
public protocol MemoryReading: Sendable {
    func allMemory() async throws -> [MemoryItem]
    func searchMemory(_ query: String) async throws -> [MemoryItem]
}

public typealias MemoryStore = NoteStore & MemoryReading

/// Storage for notes. `all` and `search` return newest first.
public protocol NoteStore: Sendable {
    func add(_ text: String) async throws -> Note
    func all() async throws -> [Note]
    func search(_ query: String) async throws -> [Note]
    func note(id: UUID) async throws -> Note?
    /// Replaces the text and keeps id and createdAt. Nil when there is no such note.
    func update(id: UUID, text: String) async throws -> Note?
    func delete(id: UUID) async throws -> Bool
    func deleteAll() async throws
}

public enum NoteSearch {
    /// True when every whitespace-separated word of `query` is found in `text`.
    /// An empty or whitespace-only query matches everything.
    public static func matches(_ text: String, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace })
        return words.allSatisfy { text.localizedStandardContains($0) }
    }
}

public actor InMemoryNoteStore: NoteStore, MemoryReading {
    private var notes: [Note] = []
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func add(_ text: String) async throws -> Note {
        let note = Note(text: text, createdAt: now())
        notes.append(note)
        return note
    }

    public func all() async throws -> [Note] { newestFirst(notes) }

    public func search(_ query: String) async throws -> [Note] {
        newestFirst(notes.filter { NoteSearch.matches($0.text, query: query) })
    }

    public func note(id: UUID) async throws -> Note? {
        notes.first { $0.id == id }
    }

    public func update(id: UUID, text: String) async throws -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let updated = Note(id: id, text: text, createdAt: notes[index].createdAt)
        notes[index] = updated
        return updated
    }

    public func allMemory() async throws -> [MemoryItem] {
        newestFirst(notes).map(Self.item(from:))
    }

    public func searchMemory(_ query: String) async throws -> [MemoryItem] {
        try await search(query).map(Self.item(from:))
    }

    private static func item(from note: Note) -> MemoryItem {
        MemoryItem(id: note.id, kind: .note, createdAt: note.createdAt, text: note.text)
    }

    public func delete(id: UUID) async throws -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        notes.remove(at: index)
        return true
    }

    public func deleteAll() async throws {
        notes.removeAll()
    }

    /// Ties on createdAt keep the later-added note first.
    private func newestFirst(_ list: [Note]) -> [Note] {
        list.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }
            .map(\.element)
    }
}
