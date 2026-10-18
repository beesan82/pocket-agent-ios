import Foundation
import PocketAgentCore
import SwiftData

@ModelActor
actor SwiftDataNoteStore: NoteStore {
    func add(_ text: String) async throws -> Note {
        Note(text: text, createdAt: Date())
    }

    func all() async throws -> [Note] { [] }

    func search(_ query: String) async throws -> [Note] { [] }

    func note(id: UUID) async throws -> Note? { nil }

    func delete(id: UUID) async throws -> Bool { false }

    func deleteAll() async throws {}
}
