import AgentRunKit
import Foundation

/// FakeLLM: replays a fixed script of assistant turns. No network.
///
/// Written against AgentRunKit 6.1.0's `LLMClient`; `Agent.run` calls `generate`
/// (via `generateForRun`), so `stream` is intentionally unsupported.
final class ScriptedLLMClient: LLMClient {
    enum Step: Sendable {
        case callTool(name: String, arguments: String)
        /// Calls AgentRunKit's reserved `finish` tool (`{"content": ...}`).
        case finish(String)
    }

    enum FakeError: Error {
        case scriptExhausted
        case streamingNotScripted
    }

    let providerIdentifier: ProviderIdentifier = .custom("scripted-fake")

    private let steps: [Step]
    private let repeatLastStep: Bool
    private let recorder = Recorder()

    init(_ steps: [Step], repeatLastStep: Bool = false) {
        self.steps = steps
        self.repeatLastStep = repeatLastStep
    }

    var generateCallCount: Int {
        get async { await recorder.requests.count }
    }

    var lastRequest: [ChatMessage] {
        get async { await recorder.requests.last ?? [] }
    }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext _: RequestContext?
    ) async throws -> AssistantMessage {
        let index = await recorder.record(messages)
        let step: Step
        if index < steps.count {
            step = steps[index]
        } else if repeatLastStep, let last = steps.last {
            step = last
        } else {
            throw FakeError.scriptExhausted
        }

        let callID = "call_\(index)"
        switch step {
        case let .callTool(name, arguments):
            return AssistantMessage(content: "", toolCalls: [ToolCall(id: callID, name: name, arguments: arguments)])
        case let .finish(content):
            let data = try JSONSerialization.data(withJSONObject: ["content": content])
            let arguments = String(decoding: data, as: UTF8.self)
            return AssistantMessage(content: "", toolCalls: [ToolCall(id: callID, name: "finish", arguments: arguments)])
        }
    }

    func stream(
        messages _: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext _: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeError.streamingNotScripted) }
    }
}

private actor Recorder {
    private(set) var requests: [[ChatMessage]] = []

    func record(_ messages: [ChatMessage]) -> Int {
        requests.append(messages)
        return requests.count - 1
    }
}
