import AgentRunKit
import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// Builds the client for a choice. `appleLocalTools` are already approval-gated and
/// belong inside the on-device client; the Claude path ignores them.
typealias ClientResolver = @MainActor (ModelChoice, _ appleLocalTools: [any AnyTool<EmptyContext>])
    -> Result<any LLMClient, ModelResolutionError>

/// One conversation on screen: runs one `AgentRunner.run` per user message and persists turns.
@MainActor
@Observable
final class ChatSession {
    enum Status: Equatable {
        case idle
        case running
        case failed(String)
    }

    nonisolated static let notFoundSummary = "該当するメモがありません"
    static let saveFailedMessage = "保存できませんでした"

    private(set) var turns: [ChatTurn]
    private(set) var status = Status.idle

    @ObservationIgnored private let conversation: ConversationRecord
    @ObservationIgnored private let repository: ConversationRepository
    @ObservationIgnored private let notes: any MemoryStore
    @ObservationIgnored private let settings: ModelSettings
    @ObservationIgnored private let resolve: ClientResolver
    @ObservationIgnored private let approvalHandler: ToolApprovalGate.ApprovalHandler
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        conversation: ConversationRecord,
        repository: ConversationRepository,
        notes: any MemoryStore,
        settings: ModelSettings,
        broker: ApprovalBroker,
        resolve: @escaping ClientResolver
    ) {
        self.conversation = conversation
        self.repository = repository
        self.notes = notes
        self.settings = settings
        self.resolve = resolve
        turns = repository.turns(of: conversation)
        // "Allow for this conversation" lives in this handler's ConversationApprovals: shared by
        // every turn and both tool paths for as long as this session (the open chat screen) exists.
        approvalHandler = ConversationApprovals().handler(asking: { [notes] request in
            let summary = await ChatSession.summary(for: request, notes: notes)
            return await broker.ask(request, summary: summary)
        })
    }

    /// The production resolver. Reads `claudeModel` at send time so settings changes apply.
    static func liveResolver(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        settings: ModelSettings
    ) -> ClientResolver {
        { choice, appleLocalTools in
            LLMClientFactory.resolver(
                credentials: credentials, availability: availability,
                claudeModel: settings.claudeModel, appleLocalTools: appleLocalTools
            ).resolve(choice)
        }
    }

    func send(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, status != .running else { return }

        let choice = settings.choice
        let previousTurns = turns
        let userTurn = ChatTurn(role: .user, text: message)
        do {
            try repository.append(userTurn, to: conversation, choice: choice)
        } catch {
            status = .failed(Self.saveFailedMessage)
            return
        }
        turns.append(userTurn)

        // Tool placement follows the choice: on-device tools run inside the client's
        // session, so they are gated there and the runner gets none.
        let handler = approvalHandler
        let tools = NoteTools.make(store: notes, limit: choice == .claude ? .claude : .appleLocal)
        let appleLocalTools: [any AnyTool<EmptyContext>] = switch choice {
        case .claude: []
        case .appleLocal: ToolApprovalGate.wrap(tools, approval: handler)
        }
        let client: any LLMClient
        switch resolve(choice, appleLocalTools) {
        case let .success(resolved):
            client = resolved
        case let .failure(error):
            status = .failed(RunFailureText.message(for: error))
            return
        }

        let runnerTools: [RegisteredTool<EmptyContext>] = switch choice {
        case .claude: tools
        case .appleLocal: []
        }
        // The on-device client accepts only system messages plus one user message
        // (AgentRunKit 6.1.0 FMMessageMapper), so earlier turns are folded into the prompt.
        let (prompt, history): (String, [ChatMessage]) = switch choice {
        case .claude:
            (message, ConversationContext.history(from: previousTurns, budget: .claude))
        case .appleLocal:
            (ConversationContext.appleLocalPrompt(history: previousTurns, message: message), [])
        }
        let runner = AgentRunner<EmptyContext>(
            client: client, tools: runnerTools, systemPrompt: ConversationContext.systemPrompt)

        status = .running
        task = Task {
            let outcome: Result<AgentRunOutcome, any Error>
            do {
                outcome = try await .success(runner.run(
                    prompt, history: history, context: EmptyContext(), approval: handler))
            } catch {
                outcome = .failure(error)
            }
            self.finish(outcome, choice: choice)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func finish(_ result: Result<AgentRunOutcome, any Error>, choice: ModelChoice) {
        task = nil
        switch result {
        case let .success(.completed(text)):
            let reply = ChatTurn(role: .assistant, text: text.isEmpty ? RunFailureText.emptyReply : text)
            do {
                try repository.append(reply, to: conversation, choice: choice)
            } catch {
                status = .failed(Self.saveFailedMessage)
                return
            }
            turns.append(reply)
            status = .idle
        case let .success(outcome):
            status = .failed(RunFailureText.message(for: outcome) ?? RunFailureText.stopped)
        case let .failure(error):
            // Never show `error` itself: transport errors can carry response bodies.
            status = .failed(LLMErrorDescriber.userMessage(for: error))
        }
    }

    /// What the approval sheet says the tool will do.
    nonisolated static func summary(for request: PendingApproval, notes: any MemoryStore) async -> String {
        switch request.toolName {
        case NoteToolName.save:
            return decodeArguments(SaveNoteArguments.self, request.arguments)?.text ?? request.arguments
        case NoteToolName.edit:
            guard let arguments = decodeArguments(EditNoteArguments.self, request.arguments) else {
                return request.arguments
            }
            guard let id = UUID(uuidString: arguments.id),
                  let old = try? await notes.note(id: id)
            else { return notFoundSummary }
            return "\(old.text) → \(arguments.text)"
        case NoteToolName.delete:
            guard let arguments = decodeArguments(DeleteNoteArguments.self, request.arguments),
                  let id = UUID(uuidString: arguments.id),
                  let note = try? await notes.note(id: id)
            else { return notFoundSummary }
            return note.text
        default:
            return request.arguments
        }
    }
}

private struct SaveNoteArguments: Decodable {
    let text: String
}

private struct EditNoteArguments: Decodable {
    let id: String
    let text: String
}

private struct DeleteNoteArguments: Decodable {
    let id: String
}

private func decodeArguments<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
    try? JSONDecoder().decode(type, from: Data(json.utf8))
}
