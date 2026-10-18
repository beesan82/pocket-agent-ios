import Foundation
import SwiftData

@Model
final class NoteRecord {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelChoiceRaw: String
    @Relationship(deleteRule: .cascade, inverse: \TurnRecord.conversation)
    var turns: [TurnRecord] = []

    init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date, modelChoiceRaw: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelChoiceRaw = modelChoiceRaw
    }
}

@Model
final class TurnRecord {
    var roleRaw: String
    var text: String
    var createdAt: Date
    var order: Int
    var conversation: ConversationRecord?

    init(roleRaw: String, text: String, createdAt: Date, order: Int) {
        self.roleRaw = roleRaw
        self.text = text
        self.createdAt = createdAt
        self.order = order
    }
}

enum AppModelContainer {
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PocketAgentSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(
            for: schema, migrationPlan: PocketAgentMigrationPlan.self, configurations: [configuration])
    }
}
