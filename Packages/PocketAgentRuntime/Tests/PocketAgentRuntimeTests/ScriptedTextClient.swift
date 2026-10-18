import AgentRunKit
import Foundation

/// FakeLLM for plain-text calls: `generate` and `stream` answer from separate scripts,
/// and every call's messages and requestContext extra fields are recorded. No network.
final class ScriptedTextClient: LLMClient, @unchecked Sendable {
    enum GenerateStep: Sendable {
        case reply(String)
        case fail
    }

    enum StreamStep: Sendable {
        /// Yields the deltas, then finishes.
        case deltas([StreamDelta])
        /// Yields the deltas, then finishes with an error.
        case deltasThenFail([StreamDelta])
        /// Yields the deltas and never finishes (until the consumer goes away).
        case hang([StreamDelta])
    }

    enum Kind: Sendable, Equatable {
        case generate, stream
    }

    struct Call: Sendable {
        let kind: Kind
        let messages: [ChatMessage]
        let extraFields: [String: JSONValue]?
    }

    enum FakeError: Error {
        case scripted
        case scriptExhausted
    }

    let providerIdentifier: ProviderIdentifier = .custom("scripted-text-fake")

    private let lock = NSLock()
    private var generateSteps: [GenerateStep]
    private var streamSteps: [StreamStep]
    private var recordedCalls: [Call] = []
    private var terminations = 0

    init(generate: [GenerateStep] = [], stream: [StreamStep] = []) {
        generateSteps = generate
        streamSteps = stream
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    /// How many scripted streams have ended (finished, failed or cancelled).
    var terminatedStreams: Int {
        lock.withLock { terminations }
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        let step: GenerateStep? = lock.withLock {
            recordedCalls.append(Call(kind: .generate, messages: messages, extraFields: requestContext?.extraFields))
            return generateSteps.isEmpty ? nil : generateSteps.removeFirst()
        }
        switch step {
        case let .reply(text): return AssistantMessage(content: text)
        case .fail: throw FakeError.scripted
        case nil: throw FakeError.scriptExhausted
        }
    }

    func stream(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let step: StreamStep? = lock.withLock {
            recordedCalls.append(Call(kind: .stream, messages: messages, extraFields: requestContext?.extraFields))
            return streamSteps.isEmpty ? nil : streamSteps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in
                lock.withLock { terminations += 1 }
            }
            switch step {
            case let .deltas(deltas):
                deltas.forEach { continuation.yield($0) }
                continuation.finish()
            case let .deltasThenFail(deltas):
                deltas.forEach { continuation.yield($0) }
                continuation.finish(throwing: FakeError.scripted)
            case let .hang(deltas):
                deltas.forEach { continuation.yield($0) }
            case nil:
                continuation.finish(throwing: FakeError.scriptExhausted)
            }
        }
    }
}
