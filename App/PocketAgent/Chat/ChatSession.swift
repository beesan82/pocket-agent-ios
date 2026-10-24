import AgentRunKit
import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// Builds the Claude client (the only model that goes through the resolver).
typealias ClientResolver = @MainActor (ModelChoice) -> Result<any LLMClient, ModelResolutionError>

/// One conversation on screen and persists its turns. Claude runs one `AgentRunner.run` per user
/// message; the on-device models (Apple and the downloaded model) run one fresh Foundation Models
/// session per message with the same note tools behind the approval sheet, streamed.
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
    /// The on-device model's reply so far; never saved until the reply completes.
    private(set) var streamingText = ""
    /// Why the last on-device send could not run (typed, so the screen can offer the fix);
    /// cleared by the next send.
    private(set) var lastFailureReason: ModelUnavailableReason?
    /// A send is in progress (loading the model or answering).
    var isBusy: Bool { status == .running || status == .loadingModel }
    /// The on-device model kept failing to use the note tools in this conversation (requirements §6.4).
    /// Follows the current selection, so it is never true while Claude is selected.
    var isToolSupportLimited: Bool {
        let current = settings.choice
        return current.isLocal && current == lastChoice && tracker.isLimited
    }

    @ObservationIgnored private let conversation: ConversationRecord
    @ObservationIgnored private let repository: ConversationRepository
    @ObservationIgnored private let notes: any MemoryStore
    @ObservationIgnored private let settings: ModelSettings
    @ObservationIgnored private let resolve: ClientResolver
    @ObservationIgnored private let onDevice: any OnDeviceModelAccess
    @ObservationIgnored private let approvalHandler: ToolApprovalGate.ApprovalHandler
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the current on-device send: a stopped send may still be waiting for the
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
        onDevice: any OnDeviceModelAccess,
        log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.conversation = conversation
        self.repository = repository
        self.notes = notes
        self.settings = settings
        self.resolve = resolve
        self.onDevice = onDevice
        self.log = log
        turns = repository.turns(of: conversation)
        // "Allow for this conversation" lives in this handler's ConversationApprovals: shared by
        // every turn, every model and rescued calls for as long as this session exists.
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
        { choice in
            LLMClientFactory.resolver(
                credentials: credentials, availability: availability, claudeModel: settings.claudeModel
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

        // On-device models never reach the resolver or the Claude credentials.
        switch choice {
        case .claude:
            sendWithClaude(message: message, previousTurns: previousTurns)
        case .appleLocal, .mlxLocal:
            sendOnDevice(choice, message: message, previousTurns: previousTurns)
        }
    }

    func stop() {
        task?.cancel()
        // Loading cannot be cancelled: release the session now and let the
        // late load completion be ignored.
        if status == .loadingModel {
            status = .failed(RunFailureText.stopped)
            // Retire the stopped send: its late completion must not touch whatever runs next
            // (any model), including clearing that run's `task`.
            localSendID += 1
        }
    }

    private func sendWithClaude(message: String, previousTurns: [ChatTurn]) {
        // AgentRunKit asks before `execute`, so only executed calls are recorded.
        let handler = approvalHandler
        let tools = NoteTools.make(store: notes, limit: .claude)
        let recorder = ToolCallRecorder()
        let client: any LLMClient
        switch resolve(.claude) {
        case let .success(resolved):
            client = resolved
        case let .failure(error):
            status = .failed(RunFailureText.message(for: error))
            return
        }
        let runnerTools = tools.map {
            RegisteredTool<EmptyContext>(RecordingTool(inner: $0.tool, recorder: recorder), risk: $0.risk)
        }

        status = .running
        task = Task {
            // Memory is optional context: a read failure must not stop the answer.
            let memory = (try? await notes.allMemory()) ?? []
            let section = ConversationContext.memorySection(memory: memory, limit: .claude)
            let runner = AgentRunner<EmptyContext>(
                client: client, tools: runnerTools,
                systemPrompt: ConversationContext.claudeSystemPrompt(memorySection: section))

            let outcome: Result<AgentRunOutcome, any Error>
            do {
                outcome = try await .success(runner.run(
                    message, history: ConversationContext.history(from: previousTurns, budget: .claude),
                    context: EmptyContext(), approval: handler))
            } catch {
                outcome = .failure(error)
            }
            let nativeTool = await recorder.firstTool
            await self.finish(outcome, turn: TurnInfo(
                choice: .claude, message: message, tools: tools, nativeTool: nativeTool))
        }
    }

    /// Apple and the downloaded model: a fresh session per turn, the note tools behind the approval
    /// sheet, earlier user turns folded into the prompt (spike D3a), the reply streamed into
    /// `streamingText`. A stopped or failed reply is never saved.
    private func sendOnDevice(_ choice: ModelChoice, message: String, previousTurns: [ChatTurn]) {
        if let reason = onDevice.reason(for: choice), reason != .modelLoading {
            // Never load a model that cannot be used now (not downloaded, unloaded for memory, …).
            fail(with: reason)
            return
        }
        status = choice == .mlxLocal ? .loadingModel : .running
        streamingText = ""
        localSendID += 1
        let sendID = localSendID
        let onDevice = onDevice
        // The recorder sits outside the gate, so a call the user denies still counts as native
        // and the same reply is never rescued and asked about again.
        let tools = NoteTools.make(store: notes, limit: .appleLocal)
        let recorder = ToolCallRecorder()
        let sessionTools: [any AnyTool<EmptyContext>] = ToolApprovalGate.wrap(tools, approval: approvalHandler)
            .map { gated -> any AnyTool<EmptyContext> in RecordingTool(inner: gated, recorder: recorder) }
        task = Task {
            defer {
                if sendID == localSendID {
                    streamingText = ""
                    task = nil
                }
            }
            // Memory is optional context: a read failure must not stop the answer.
            let memory = (try? await notes.allMemory()) ?? []
            let section = ConversationContext.memorySection(memory: memory, limit: .appleLocal)
            let runner = await onDevice.runner(for: choice)
            if Task.isCancelled {
                // `stop()` already reported it; a later send may own the status by now.
                if sendID == localSendID { status = .failed(RunFailureText.stopped) }
                return
            }
            guard let runner else {
                if let reason = onDevice.reason(for: choice) {
                    fail(with: reason)
                } else {
                    status = .failed(MLXRuntime.loadFailedText)
                }
                return
            }
            status = .running
            var reply = ""
            do {
                let stream = runner.run(
                    instructions: ConversationContext.onDeviceInstructions(memorySection: section),
                    prompt: LocalAgentPrompt.fold(previous: previousTurns, current: message),
                    tools: sessionTools)
                for try await chunk in stream {
                    reply += chunk
                    streamingText = reply
                }
            } catch {
                // Never show `error` itself: it may carry model output.
                if Task.isCancelled || error is CancellationError {
                    status = .failed(RunFailureText.stopped)
                } else if onDevice.reason(for: choice) == .unloadedForMemory {
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
            // A memory warning drops the model at once while the screen's stop() comes later,
            // so the stream can end "normally" with a cut-off reply: never save it.
            if onDevice.reason(for: choice) == .unloadedForMemory {
                fail(with: .unloadedForMemory)
                return
            }
            let nativeTool = await recorder.firstTool
            await complete(reply, turn: TurnInfo(choice: choice, message: message, tools: tools, nativeTool: nativeTool))
        }
    }

    private func fail(with reason: ModelUnavailableReason) {
        lastFailureReason = reason
        status = .failed(reason.userMessage)
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
            await complete(text, turn: turn)
        case let .success(outcome):
            status = .failed(RunFailureText.message(for: outcome) ?? RunFailureText.stopped)
        case let .failure(error):
            // Never show `error` itself: transport errors can carry response bodies.
            status = .failed(LLMErrorDescriber.userMessage(for: error))
        }
    }

    /// A finished reply: rescue a tool call written as JSON when none ran natively, then save and log.
    private func complete(_ text: String, turn: TurnInfo) async {
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
            try repository.append(reply, to: conversation, choice: turn.choice)
        } catch {
            status = .failed(Self.saveFailedMessage)
            return
        }
        turns.append(reply)
        // Only a completed, saved turn is logged and counted.
        record(use, turn: turn)
        status = .idle
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

    /// Measurement log for every completed turn; capability evidence for the on-device models only.
    private func record(_ use: ToolUse, turn: TurnInfo) {
        let model = "model=\(turn.choice.rawValue)"
        switch use {
        case let .native(tool): self.log("toolcall.native \(model) tool=\(tool)")
        case let .rescued(tool): self.log("toolcall.rescued \(model) tool=\(tool)")
        case .ambiguous: self.log("toolcall.ambiguous \(model)")
        case .none: self.log("toolcall.none \(model)")
        }
        guard turn.choice.isLocal else { return }
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
