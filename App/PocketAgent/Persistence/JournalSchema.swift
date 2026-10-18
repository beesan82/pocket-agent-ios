import Foundation
import SwiftData

/// A journal entry as stored. `sequence` grows by one per insert so entries
/// with the same `createdAt` still have a fixed order.
@Model
final class JournalEntryRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var sequence: Int
    var sourceRaw: String
    var originRaw: String
    var body: String
    var transcript: String?
    var title: String?

    init(
        id: UUID = UUID(), createdAt: Date, sequence: Int, sourceRaw: String, originRaw: String,
        body: String, transcript: String? = nil, title: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sequence = sequence
        self.sourceRaw = sourceRaw
        self.originRaw = originRaw
        self.body = body
        self.transcript = transcript
        self.title = title
    }
}

// The model classes stay top-level and each version lists them; a model that
// changes later has to be copied into its version's namespace first.

/// The store as shipped before the journal: notes and conversations.
enum PocketAgentSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [NoteRecord.self, ConversationRecord.self, TurnRecord.self]
    }
}

/// Adds journal entries. Notes are copied into the journal by `NoteMigration`.
enum PocketAgentSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [NoteRecord.self, ConversationRecord.self, TurnRecord.self, JournalEntryRecord.self]
    }
}

enum PocketAgentMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PocketAgentSchemaV1.self, PocketAgentSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: PocketAgentSchemaV1.self, toVersion: PocketAgentSchemaV2.self)]
    }
}
