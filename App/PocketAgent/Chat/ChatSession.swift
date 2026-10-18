import AgentRunKit
import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

typealias ClientResolver = @MainActor (ModelChoice, _ appleLocalTools: [any AnyTool<EmptyContext>])
    -> Result<any LLMClient, ModelResolutionError>

@MainActor
@Observable
final class ChatSession {
    enum Status: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var turns: [ChatTurn] = []
    private(set) var status = Status.idle

    init(
        conversation: ConversationRecord,
        repository: ConversationRepository,
        notes: any NoteStore,
        settings: ModelSettings,
        broker: ApprovalBroker,
        resolve: @escaping ClientResolver
    ) {}

    static func liveResolver(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        settings: ModelSettings
    ) -> ClientResolver {
        { _, _ in .failure(.clientCreationFailed) }
    }

    func send(_ text: String) {}

    func stop() {}

    nonisolated static func summary(for request: PendingApproval, notes: any NoteStore) async -> String {
        ""
    }
}
