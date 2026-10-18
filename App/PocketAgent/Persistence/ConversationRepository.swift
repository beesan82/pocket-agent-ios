import Foundation
import PocketAgentCore
import SwiftData

@MainActor
final class ConversationRepository {
    static let defaultTitle = "新しい会話"
    static let titleLength = 30

    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func create(choice: ModelChoice) throws -> ConversationRecord {
        let now = Date()
        let record = ConversationRecord(
            title: Self.defaultTitle, createdAt: now, updatedAt: now, modelChoiceRaw: choice.rawValue)
        context.insert(record)
        try save()
        return record
    }

    func append(_ turn: ChatTurn, to conversation: ConversationRecord, choice: ModelChoice) throws {
        let now = Date()
        let isFirstUserTurn = turn.role == .user
            && !conversation.turns.contains { $0.roleRaw == ChatTurn.Role.user.rawValue }
        let record = TurnRecord(
            roleRaw: turn.role.rawValue, text: turn.text, createdAt: now,
            order: conversation.turns.count)
        record.conversation = conversation
        context.insert(record)
        if isFirstUserTurn {
            let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                conversation.title = String(trimmed.prefix(Self.titleLength))
            }
        }
        conversation.updatedAt = now
        conversation.modelChoiceRaw = choice.rawValue
        try save()
    }

    /// On failure, discards the pending changes so a later save cannot commit them.
    private func save() throws {
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func turns(of conversation: ConversationRecord) -> [ChatTurn] {
        conversation.turns
            .sorted { $0.order < $1.order }
            .compactMap { record in
                ChatTurn.Role(rawValue: record.roleRaw).map { ChatTurn(role: $0, text: record.text) }
            }
    }

    func all() throws -> [ConversationRecord] {
        try context.fetch(
            FetchDescriptor<ConversationRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    func delete(_ conversation: ConversationRecord) throws {
        context.delete(conversation)
        try save()
    }

    func deleteAll() throws {
        // Delete per object so the cascade rule removes the turns.
        for conversation in try context.fetch(FetchDescriptor<ConversationRecord>()) {
            context.delete(conversation)
        }
        try save()
    }
}

enum DataReset {
    /// Erases conversations, the journal (notes included), the API key and the GitHub token. Every step is attempted;
    /// the first error is thrown afterwards.
    @MainActor
    static func eraseAll(
        context: ModelContext, journal: any JournalStore, credentials: any CredentialStore,
        githubToken: any CredentialStore
    ) async throws {
        var firstError: Error?
        do { try ConversationRepository(context: context).deleteAll() } catch { firstError = firstError ?? error }
        do { try await journal.deleteAll() } catch { firstError = firstError ?? error }
        do { try credentials.deleteAPIKey() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }
}
