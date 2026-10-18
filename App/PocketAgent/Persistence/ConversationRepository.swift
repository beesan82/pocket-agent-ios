import Foundation
import PocketAgentCore
import SwiftData

@MainActor
final class ConversationRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func create(choice: ModelChoice) throws -> ConversationRecord {
        let now = Date()
        let record = ConversationRecord(
            title: "新しい会話", createdAt: now, updatedAt: now, modelChoiceRaw: choice.rawValue)
        context.insert(record)
        try context.save()
        return record
    }

    func append(_ turn: ChatTurn, to conversation: ConversationRecord, choice: ModelChoice) throws {}

    func turns(of conversation: ConversationRecord) -> [ChatTurn] { [] }

    func all() throws -> [ConversationRecord] { [] }

    func delete(_ conversation: ConversationRecord) throws {}

    func deleteAll() throws {}
}

enum DataReset {
    @MainActor
    static func eraseAll(
        context: ModelContext, notes: any NoteStore, credentials: any CredentialStore
    ) async throws {}
}
