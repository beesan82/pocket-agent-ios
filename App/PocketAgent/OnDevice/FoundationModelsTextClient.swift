import AgentRunKit
import Foundation
import FoundationModels

/// Text generation on an on-device model for the journal, the meeting notes and the MLX check
/// screen, behind AgentRunKit's `LLMClient` so `JournalAssistant` is unchanged. Every call is a
/// fresh single-turn session: system messages become the instructions, the rest one prompt.
/// Tools are never passed (these callers send none).
struct FoundationModelsTextClient: LLMClient {
    let model: any OnDeviceLanguageModel

    var providerIdentifier: ProviderIdentifier { .foundationModels }

    func generate(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        responseFormat _: ResponseFormat?,
        requestContext: RequestContext?
    ) async throws -> AssistantMessage {
        let (instructions, prompt) = Self.split(messages)
        let session = makeOnDeviceSession(model, instructions: instructions)
        let response = try await session.respond(to: prompt, options: OnDeviceGeneration.from(requestContext).options)
        return AssistantMessage(content: response.content)
    }

    func stream(
        messages: [ChatMessage],
        tools _: [ToolDefinition],
        requestContext: RequestContext?
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let (instructions, prompt) = Self.split(messages)
        let options = OnDeviceGeneration.from(requestContext).options
        let model = model
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    let session = makeOnDeviceSession(model, instructions: instructions)
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let delta = Self.delta(from: sent, to: snapshot.content)
                        if !delta.isEmpty { continuation.yield(.content(delta)) }
                        sent = snapshot.content
                    }
                    continuation.yield(.finished(usage: nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Snapshots are cumulative: the new suffix, or the whole text if it was rewritten.
    static func delta(from sent: String, to current: String) -> String {
        current.hasPrefix(sent) ? String(current.dropFirst(sent.count)) : current
    }

    static func split(_ messages: [ChatMessage]) -> (instructions: String, prompt: String) {
        var system: [String] = []
        var rest: [String] = []
        for message in messages {
            switch message {
            case let .system(text): system.append(text)
            case let .user(text): rest.append(text)
            case let .assistant(reply): rest.append(reply.content)
            case .userMultimodal, .tool: continue
            }
        }
        return (system.joined(separator: "\n\n"), rest.joined(separator: "\n\n"))
    }
}
