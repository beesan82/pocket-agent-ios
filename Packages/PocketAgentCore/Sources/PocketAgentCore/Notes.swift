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

/// Storage for notes. `all` and `search` return newest first.
public protocol NoteStore: Sendable {
    func add(_ text: String) async throws -> Note
    func all() async throws -> [Note]
    func search(_ query: String) async throws -> [Note]
    func note(id: UUID) async throws -> Note?
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

public actor InMemoryNoteStore: NoteStore {
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
