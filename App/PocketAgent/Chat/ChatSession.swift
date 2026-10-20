import AgentRunKit
import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// Builds the client for a choice. `appleLocalTools` are already approval-gated and
/// belong inside the on-device client; the Claude path ignores them.
typealias ClientResolver = @MainActor (ModelChoice, _ appleLocalTools: [any AnyTool<EmptyContext>])
    -> Result<any LLMClient, ModelResolutionError>

/// One conversation on screen and persists its turns. Claude and the Apple model run one
/// `AgentRunner.run` per user message; the downloaded model streams a text-only reply.
@MainActor
@Observable
final class ChatSession {
    enum Status: Equatable {
        case idle
        /// The downloaded model is being loaded before it can answer.
        case loadingModel
        case running
        case failed(String)
    }

    nonisolated static let notFoundSummary = "該当するメモがありません"
    static let saveFailedMessage = "保存できませんでした"
    static let rescueFailedMessage = "操作できませんでした"

    private(set) var turns: [ChatTurn]
    private(set) var status = Status.idle
    /// The downloaded model's reply so far; never saved until the reply completes.
    private(set) var streamingText = ""
    /// Why the last downloaded-model send could not run (typed, so the screen can offer the fix);
    /// cleared by the next send.
    private(set) var lastFailureReason: ModelUnavailableReason?
    /// A send is in progress (loading the model or answering).
    var isBusy: Bool { status == .running || status == .loadingModel }
    /// The Apple model kept failing to use the note tools in this conversation (requirements §6.4).
    /// Follows the current selection, so it is only ever true while the Apple model is selected.
    var isToolSupportLimited: Bool {
        let current = settings.choice
        return current == .appleLocal && current == lastChoice && tracker.isLimited
    }

    @ObservationIgnored private let conversation: ConversationRecord
    @ObservationIgnored private let repository: ConversationRepository
    @ObservationIgnored private let notes: any MemoryStore
    @ObservationIgnored private let settings: ModelSettings
    @ObservationIgnored private let resolve: ClientResolver
    @ObservationIgnored private let localModel: any LocalModelAccess
    @ObservationIgnored private let approvalHandler: ToolApprovalGate.ApprovalHandler
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the current downloaded-model send: a stopped send may still be waiting for the
    /// model to load and must not touch the state of a later one.
    @ObservationIgnored private var localSendID = 0
    // Observed: `isToolSupportLimited` is derived from these.
    private var tracker = ToolCapabilityTracker()
    private var lastChoice: ModelChoice?

    init(
        conversation: ConversationRecord,
        repository: ConversationRepository,
        notes: any MemoryStore,
        settings: ModelSettings,
        broker: ApprovalBroker,
        resolve: @escaping ClientResolver,
        localModel: any LocalModelAccess,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.conversation = conversation
        self.repository = repository
        self.notes = notes
        self.settings = settings
        self.resolve = resolve
        self.localModel = localModel
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
        guard !message.isEmpty, !isBusy else { return }
        lastFailureReason = nil

        let choice = settings.choice
        // Capability evidence is per model: switching models starts over.
        if choice != lastChoice {
            tracker.reset()
            lastChoice = choice
        }

        let previousTurns = turns
        let userTurn = ChatTurn(role: .user, text: message)
        do {
            try repository.append(userTurn, to: conversation, choice: choice)
        } catch {
            status = .failed(Self.saveFailedMessage)
            return
        }
        turns.append(userTurn)

        // Each model has its own path: the downloaded model never reaches the resolver,
        // the note tools or the Claude credentials.
        switch choice {
        case .claude:
            sendWithAgent(.claude, message: message, previousTurns: previousTurns)
        case .appleLocal:
            sendWithAgent(.appleLocal, message: message, previousTurns: previousTurns)
        case .mlxLocal:
            sendLocal(message: message, previousTurns: previousTurns)
        }
    }

    func stop() {
        task?.cancel()
        // Loading the model cannot be cancelled: release the session now and let the
        // late load completion be ignored.
        if status == .loadingModel {
            status = .failed(RunFailureText.stopped)
        }
    }

    /// The models that run through `AgentRunner` with the note tools.
    private enum AgentModel: Equatable {
        case claude
        case appleLocal

        var choice: ModelChoice {
            switch self {
            case .claude: .claude
            case .appleLocal: .appleLocal
            }
        }
    }

    private func sendWithAgent(_ model: AgentModel, message: String, previousTurns: [ChatTurn]) {
        // Tool placement follows the model: on-device tools run inside the client's
        // session, so they are gated there and the runner gets none. Every tool records
        // its native calls, so a native call is told apart from a missed one:
        // - Claude: AgentRunKit asks before `execute`, so only executed calls are recorded.
        // - On device: the recorder sits outside the gate, so a call the user denies still
        //   counts as native and the same reply is never rescued and asked about again.
        let handler = approvalHandler
        let noteLimit: NoteResultLimit = switch model {
        case .claude: .claude
        case .appleLocal: .appleLocal
        }
        let tools = NoteTools.make(store: notes, limit: noteLimit)
        let recorder = ToolCallRecorder()
        let appleLocalTools: [any AnyTool<EmptyContext>] = switch model {
        case .claude: []
        case .appleLocal: ToolApprovalGate.wrap(tools, approval: handler).map { gated -> any AnyTool<EmptyContext> in
                RecordingTool(inner: gated, recorder: recorder)
            }
        }
        let client: any LLMClient
        switch resolve(model.choice, appleLocalTools) {
        case let .success(resolved):
            client = resolved
        case let .failure(error):
            status = .failed(RunFailureText.message(for: error))
            return
        }
        let runnerTools: [RegisteredTool<EmptyContext>] = switch model {
        case .claude: tools.map {
                RegisteredTool<EmptyContext>(RecordingTool(inner: $0.tool, recorder: recorder), risk: $0.risk)
            }
        case .appleLocal: []
        }

        status = .running
        task = Task {
            // Memory is optional context: a read failure must not stop the answer.
            let memory = (try? await notes.allMemory()) ?? []
            // The on-device client accepts only system messages plus one user message
            // (AgentRunKit 6.1.0 FMMessageMapper), so earlier turns and memory go into the prompt.
            let systemPrompt: String
            let prompt: String
            let history: [ChatMessage]
            switch model {
            case .claude:
                let section = ConversationContext.memorySection(memory: memory, limit: .claude)
                systemPrompt = ConversationContext.claudeSystemPrompt(memorySection: section)
                prompt = message
                history = ConversationContext.history(from: previousTurns, budget: .claude)
            case .appleLocal:
                let section = ConversationContext.memorySection(memory: memory, limit: .appleLocal)
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
                model: model, message: message, tools: tools, nativeTool: nativeTool))
        }
    }

    /// The downloaded model: text only (no tools, no rescue, no tool-call metrics), streamed
    /// into `streamingText`. A stopped or failed reply is never saved.
    private func sendLocal(message: String, previousTurns: [ChatTurn]) {
        if let reason = localModel.reason(), reason != .modelLoading {
            // Never load a model that is not downloaded or was unloaded for memory.
            fail(with: reason)
            return
        }
        status = .loadingModel
        streamingText = ""
        localSendID += 1
        let sendID = localSendID
        let localModel = localModel
        task = Task {
            defer {
                if sendID == localSendID {
                    streamingText = ""
                    task = nil
                }
            }
            // Memory is optional context. The section is not deducted from the history budget,
            // so it uses the small on-device limit.
            let memory = (try? await notes.allMemory()) ?? []
            let section = ConversationContext.memorySection(memory: memory, limit: .appleLocal)
            let client = await localModel.client()
            if Task.isCancelled {
                // `stop()` already reported it; a later send may own the status by now.
                if sendID == localSendID { status = .failed(RunFailureText.stopped) }
                return
            }
            guard let client else {
                if let reason = localModel.reason() {
                    fail(with: reason)
                } else {
                    status = .failed(MLXRuntime.loadFailedText)
                }
                return
            }
            status = .running
            let messages = LocalChat.messages(memorySection: section, history: previousTurns, message: message)
            var reply = ""
            do {
                for try await chunk in LocalChat.stream(client: client, messages: messages) {
                    reply += chunk
                    streamingText = reply
                }
            } catch {
                // Never show `error` itself: it may carry model output.
                if Task.isCancelled || error is CancellationError {
                    status = .failed(RunFailureText.stopped)
                } else if localModel.reason() == .unloadedForMemory {
                    fail(with: .unloadedForMemory)
                } else {
                    status = .failed(LLMErrorDescriber.userMessage(for: error))
                }
                return
            }
            // A cancelled consumer ends the stream without an error.
            if Task.isCancelled {
                status = .failed(RunFailureText.stopped)
                return
            }
            // A memory warning drops the client at once while the screen's stop() comes later,
            // so the stream can end "normally" with a cut-off reply: never save it.
            if localModel.reason() == .unloadedForMemory {
                fail(with: .unloadedForMemory)
                return
            }
            let turn = ChatTurn(role: .assistant, text: reply.isEmpty ? RunFailureText.emptyReply : reply)
            do {
                try repository.append(turn, to: conversation, choice: .mlxLocal)
            } catch {
                status = .failed(Self.saveFailedMessage)
                return
            }
            turns.append(turn)
            status = .idle
        }
    }

    private func fail(with reason: ModelUnavailableReason) {
        lastFailureReason = reason
        status = .failed(reason.userMessage)
    }

    /// What `finish` needs to know about one send.
    private struct TurnInfo {
        let model: AgentModel
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
            // `stop()` may have landed after the run returned (e.g. while reading the recorder).
            if Task.isCancelled {
                status = .failed(RunFailureText.stopped)
                return
            }
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
            let reply = ChatTurn(role: .assistant, text: replyText.isEmpty ? RunFailureText.emptyReply : replyText)
            do {
                try repository.append(reply, to: conversation, choice: turn.model.choice)
            } catch {
                status = .failed(Self.saveFailedMessage)
                return
            }
            turns.append(reply)
            // Only a completed, saved turn is logged and counted.
            record(use, turn: turn)
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
        let model = "model=\(turn.model.choice.rawValue)"
        switch use {
        case let .native(tool): self.log("toolcall.native \(model) tool=\(tool)")
        case let .rescued(tool): self.log("toolcall.rescued \(model) tool=\(tool)")
        case .ambiguous: self.log("toolcall.ambiguous \(model)")
        case .none: self.log("toolcall.none \(model)")
        }
        guard turn.model == .appleLocal else { return }
        switch use {
        case .native: tracker.recordNativeToolCall()
        case .rescued: tracker.recordRescue()
        case .ambiguous: break
        case .none: tracker.recordNoToolCall(userMessage: turn.message)
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

/// Notes which tools actually executed during one send.
private actor ToolCallRecorder {
    private(set) var firstTool: String?

    func record(_ name: String) {
        if firstTool == nil { firstTool = name }
    }
}

/// Forwards everything to `inner` and records the call when the model makes it.
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
