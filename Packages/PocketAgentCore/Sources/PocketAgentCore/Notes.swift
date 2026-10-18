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
        false
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

    public func all() async throws -> [Note] { notes }

    public func search(_ query: String) async throws -> [Note] { notes }

    public func note(id: UUID) async throws -> Note? { nil }

    public func delete(id: UUID) async throws -> Bool { true }

    public func deleteAll() async throws {}
}
