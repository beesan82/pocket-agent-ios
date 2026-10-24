import AgentRunKit
import Foundation
import PocketAgentCore
@testable import PocketAgent

/// The on-device models as `ChatSession` sees them. `holdsLoad` keeps `runner(for:)` waiting until
/// `releaseLoad()`, like a downloaded model that is still loading.
@MainActor
final class FakeOnDeviceModel: OnDeviceModelAccess {
    var reasons: [ModelChoice: ModelUnavailableReason]
    private let turnRunner: (any OnDeviceTurnRunner)?
    /// Whether the next `runner(for:)` call waits for `releaseLoad()`.
    var holdsLoadForNextCall: Bool
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private(set) var runnerCalls = 0

    init(
        runner: (any OnDeviceTurnRunner)? = nil,
        reasons: [ModelChoice: ModelUnavailableReason] = [:],
        holdsLoad: Bool = false
    ) {
        turnRunner = runner
        self.reasons = reasons
        holdsLoadForNextCall = holdsLoad
    }

    func reason(for choice: ModelChoice) -> ModelUnavailableReason? { reasons[choice] }

    func runner(for _: ModelChoice) async -> (any OnDeviceTurnRunner)? {
        runnerCalls += 1
        if holdsLoadForNextCall {
            await withCheckedContinuation { loadWaiter = $0 }
        }
        return turnRunner
    }

    func releaseLoad() {
        loadWaiter?.resume()
        loadWaiter = nil
    }
}

/// What a turn was asked to do.
struct TurnCall: Equatable {
    let instructions: String
    let prompt: String
}

/// Runs one script per turn. `.callTool` calls the passed (gated, recorded) tool the way the model
/// would natively, then streams the tool's result as reply text; `.text` streams text.
final class ScriptedTurnRunner: OnDeviceTurnRunner, @unchecked Sendable {
    enum Step: Sendable {
        case callTool(String, String)
        case text(String)
    }

    enum FakeError: Error { case scriptExhausted }

    private let lock = NSLock()
    private let scripts: [[Step]]
    private var recorded: [TurnCall] = []

    init(_ scripts: [[Step]]) { self.scripts = scripts }

    var calls: [TurnCall] { lock.withLock { recorded } }

    func run(instructions: String, prompt: String, tools: [any AnyTool<EmptyContext>]) -> AsyncThrowingStream<String, Error> {
        let index = lock.withLock {
            recorded.append(TurnCall(instructions: instructions, prompt: prompt))
            return recorded.count - 1
        }
        let script = index < scripts.count ? scripts[index] : nil
        return AsyncThrowingStream { continuation in
            let pump = Task {
                guard let script else {
                    continuation.finish(throwing: FakeError.scriptExhausted)
                    return
                }
                do {
                    for step in script {
                        switch step {
                        case let .callTool(name, arguments):
                            continuation.yield(try await NoteToolBridge.invoke(name, argumentsJSON: arguments, tools: tools))
                        case let .text(text):
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}

/// A turn the test drives chunk by chunk (like a streaming model).
final class GatedTurnRunner: OnDeviceTurnRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var recorded: [TurnCall] = []
    private var terminated = false

    var calls: [TurnCall] { lock.withLock { recorded } }
    /// The current turn's stream ended (finished, failed or its consumer went away).
    var isTerminated: Bool { lock.withLock { terminated } }

    func run(instructions: String, prompt: String, tools _: [any AnyTool<EmptyContext>]) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.withLock { terminated = true }
        }
        lock.withLock {
            recorded.append(TurnCall(instructions: instructions, prompt: prompt))
            terminated = false
            self.continuation = continuation
        }
        return stream
    }

    func yield(_ text: String) {
        _ = lock.withLock { continuation }?.yield(text)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }
}
