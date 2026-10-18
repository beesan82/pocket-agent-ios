import AgentRunKit
import Foundation
import PocketAgentCore

public struct NoteResultLimit: Sendable {
    public let maxNotes: Int
    public let maxCharactersPerNote: Int?

    public init(maxNotes: Int, maxCharactersPerNote: Int?) {
        self.maxNotes = maxNotes
        self.maxCharactersPerNote = maxCharactersPerNote
    }

    public static let claude = NoteResultLimit(maxNotes: 50, maxCharactersPerNote: nil)
    public static let appleLocal = NoteResultLimit(maxNotes: 10, maxCharactersPerNote: 200)
}

public enum NoteToolName {
    public static let save = "save_note"
    public static let list = "list_notes"
    public static let search = "search_notes"
    public static let delete = "delete_note"
}

public enum NoteTools {
    public static let maxNoteLength = 2000

    public static func make(store: any NoteStore, limit: NoteResultLimit) -> [RegisteredTool<EmptyContext>] {
        []
    }
}
