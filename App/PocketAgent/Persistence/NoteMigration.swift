import Foundation
import PocketAgentCore
import SwiftData

/// Moves the notes saved before the journal existed into the journal, once.
enum NoteMigration {
    static let flagKey = "pocketagent.notesMigrated"

    /// Copies every `NoteRecord` into a `.text` / `.noteTool` journal entry with the same
    /// id and `createdAt`, then deletes the notes. On a failure the pending changes are
    /// rolled back and the flag stays unset, so the next launch tries again. Ids are unique,
    /// so a retry after the first save updates the copied entries instead of duplicating them.
    @MainActor
    static func migrateOnce(context: ModelContext, defaults: UserDefaults) throws {
        guard !defaults.bool(forKey: flagKey) else { return }
        do {
            let notes = try context.fetch(
                FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.createdAt)]))
            var sequence = try SwiftDataJournalStore.nextSequence(in: context)
            for note in notes {
                context.insert(JournalEntryRecord(
                    id: note.id, createdAt: note.createdAt, sequence: sequence,
                    sourceRaw: JournalEntry.Source.text.rawValue,
                    originRaw: JournalEntry.Origin.noteTool.rawValue, body: note.text))
                sequence += 1
            }
            try context.save()
            for note in notes {
                context.delete(note)
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        defaults.set(true, forKey: flagKey)
    }
}
