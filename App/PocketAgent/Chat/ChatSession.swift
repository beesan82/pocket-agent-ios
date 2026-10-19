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
    static let rescueFailedMessage = "操作できませんでした"

    private(set) var turns: [ChatTurn]
    private(set) var status = Status.idle
    /// The on-device model kept failing to use the note tools in this conversation (requirements §6.4).
    /// Never true for Claude.
    private(set) var isToolSupportLimited = false

    @ObservationIgnored private let conversation: ConversationRecord
    @ObservationIgnored private let repository: ConversationRepository
    @ObservationIgnored private let notes: any MemoryStore
    @ObservationIgnored private let settings: ModelSettings
    @ObservationIgnored private let resolve: ClientResolver
    @ObservationIgnored private let approvalHandler: ToolApprovalGate.ApprovalHandler
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tracker = ToolCapabilityTracker()
    @ObservationIgnored private var lastChoice: ModelChoice?

    init(
        conversation: ConversationRecord,
        repository: ConversationRepository,
        notes: any MemoryStore,
        settings: ModelSettings,
        broker: ApprovalBroker,
        resolve: @escaping ClientResolver,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.conversation = conversation
        self.repository = repository
        self.notes = notes
        self.settings = settings
        self.resolve = resolve
        self.log = log
        turns = repository.turns(of: conversation)
        // "Allow for this conversation" lives in this handler's ConversationApprovals: shared by
        // every turn, both tool paths and rescued calls for as long as this session exists.
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
        // Capability evidence is per model: switching models starts over.
        if choice != lastChoice {
            tracker.reset()
            lastChoice = choice
        }
        if choice == .claude { isToolSupportLimited = false }

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
        // session, so they are gated there and the runner gets none. Every tool records
        // when it actually executes, so a native call is told apart from a missed one.
        let handler = approvalHandler
        let tools = NoteTools.make(store: notes, limit: choice == .claude ? .claude : .appleLocal)
        let recorder = ToolCallRecorder()
        let recordingTools = tools.map {
            RegisteredTool<EmptyContext>(RecordingTool(inner: $0.tool, recorder: recorder), risk: $0.risk)
        }
        let appleLocalTools: [any AnyTool<EmptyContext>] = switch choice {
        case .claude: []
        case .appleLocal: ToolApprovalGate.wrap(recordingTools, approval: handler)
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
        case .claude: recordingTools
        case .appleLocal: []
        }

        status = .running
        task = Task {
            // Memory is optional context: a read failure must not stop the answer.
            let memory = (try? await notes.allMemory()) ?? []
            let section = ConversationContext.memorySection(
                memory: memory, limit: choice == .claude ? .claude : .appleLocal)
            // The on-device client accepts only system messages plus one user message
            // (AgentRunKit 6.1.0 FMMessageMapper), so earlier turns and memory go into the prompt.
            let systemPrompt: String
            let prompt: String
            let history: [ChatMessage]
            switch choice {
            case .claude:
                systemPrompt = ConversationContext.claudeSystemPrompt(memorySection: section)
                prompt = message
                history = ConversationContext.history(from: previousTurns, budget: .claude)
            case .appleLocal:
                systemPrompt = ConversationContext.systemPrompt
                prompt = ConversationContext.appleLocalPrompt(
                    history: previousTurns, message: message, memorySection: section)
                history = []
            }
            let runner = AgentRunner<EmptyContext>(client: client, tools: runnerTools, systemPrompt: systemPrompt)

            let outcome: Result<AgentRunOutcome, any Error>
            do {
                outcome = try await .success(runner.run(
                    prompt, history: history, context: EmptyContext(), approval: handler))
            } catch {
                outcome = .failure(error)
            }
            let nativeTool = await recorder.firstTool
            await self.finish(outcome, turn: TurnInfo(
                choice: choice, message: message, tools: tools, nativeTool: nativeTool))
        }
    }

    func stop() {
        task?.cancel()
    }

    /// What `finish` needs to know about one send.
    private struct TurnInfo {
        let choice: ModelChoice
        let message: String
        /// The plain tools (not gated, not recorded): a rescued call runs these after its own approval.
        let tools: [RegisteredTool<EmptyContext>]
        /// The first tool the model called natively and that actually executed.
        let nativeTool: String?
    }

    private enum ToolUse {
        case native(String)
        case rescued(String)
        case ambiguous
        case none
    }

    private func finish(_ result: Result<AgentRunOutcome, any Error>, turn: TurnInfo) async {
        // Cleared only at the end: `stop()` must still reach the task while a rescue waits for approval.
        defer { task = nil }
        switch result {
        case let .success(.completed(text)):
            let use: ToolUse
            var replyText = text
            if let native = turn.nativeTool {
                // A native call already happened: never run a second, rescued one.
                use = .native(native)
            } else {
                switch ToolCallRescue.extract(from: text, knownTools: ToolCallRescue.knownTools(turn.tools)) {
                case let .found(call):
                    guard let rescued = await runRescued(call, original: text, tools: turn.tools) else {
                        status = .failed(RunFailureText.stopped)
                        return
                    }
                    replyText = rescued
                    use = .rescued(call.toolName)
                case .ambiguous:
                    use = .ambiguous
                case .none:
                    use = .none
                }
            }
            record(use, turn: turn)

            let reply = ChatTurn(role: .assistant, text: replyText.isEmpty ? RunFailureText.emptyReply : replyText)
            do {
                try repository.append(reply, to: conversation, choice: turn.choice)
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

    /// Runs a tool call the model wrote as JSON, behind the same approval as a native call.
    /// Returns the reply text to save, or nil when the user stopped the turn.
    private func runRescued(
        _ call: RescuedToolCall, original text: String, tools: [RegisteredTool<EmptyContext>]
    ) async -> String? {
        // `knownTools` came from `tools`, so the name always matches.
        guard let registered = tools.first(where: { $0.tool.name == call.toolName }) else { return text }
        // Always asked, even for read-only tools: the model never actually called this tool.
        let decision = await approvalHandler(PendingApproval(
            toolName: call.toolName, toolDescription: registered.tool.description,
            arguments: call.arguments, risk: registered.risk))
        // The user may have stopped the turn while the dialog was open.
        if Task.isCancelled { return nil }
        if case .deny = decision { return text }
        let result: ToolResult
        do {
            result = try await registered.tool.execute(arguments: Data(call.arguments.utf8), context: EmptyContext())
        } catch is CancellationError {
            return nil
        } catch {
            // Never show `error` itself.
            result = .error(Self.rescueFailedMessage)
        }
        let resultText = ToolCallRescue.resultText(toolName: call.toolName, result: result)
        return call.remainingText.isEmpty ? resultText : call.remainingText + "\n\n" + resultText
    }

    /// Measurement log for every completed turn; capability evidence for the on-device model only.
    private func record(_ use: ToolUse, turn: TurnInfo) {
        let model = "model=\(turn.choice.rawValue)"
        switch use {
        case let .native(tool): self.log("toolcall.native \(model) tool=\(tool)")
        case let .rescued(tool): self.log("toolcall.rescued \(model) tool=\(tool)")
        case .ambiguous: self.log("toolcall.ambiguous \(model)")
        case .none: self.log("toolcall.none \(model)")
        }
        guard turn.choice != .claude else {
            isToolSupportLimited = false
            return
        }
        switch use {
        case .native: tracker.recordNativeToolCall()
        case .rescued: tracker.recordRescue()
        case .ambiguous: break
        case .none: tracker.recordNoToolCall(userMessage: turn.message)
        }
        isToolSupportLimited = tracker.isLimited
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

/// Notes which tools actually executed during one send.
private actor ToolCallRecorder {
    private(set) var firstTool: String?

    func record(_ name: String) {
        if firstTool == nil { firstTool = name }
    }
}

/// Forwards everything to `inner` and records the call when it executes.
/// It sits inside the approval gate, so a denied call is never recorded.
private struct RecordingTool: AnyTool {
    typealias Context = EmptyContext

    let inner: any AnyTool<EmptyContext>
    let recorder: ToolCallRecorder

    var name: String { inner.name }
    var description: String { inner.description }
    var parametersSchema: JSONSchema { inner.parametersSchema }
    var isConcurrencySafe: Bool { inner.isConcurrencySafe }
    var isReadOnly: Bool { inner.isReadOnly }
    var maxResultCharacters: Int? { inner.maxResultCharacters }
    var toolTimeout: Duration? { inner.toolTimeout }
    var strict: Bool? { inner.strict }

    func execute(arguments: Data, context: EmptyContext) async throws -> ToolResult {
        await recorder.record(inner.name)
        return try await inner.execute(arguments: arguments, context: context)
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
