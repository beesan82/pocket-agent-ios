import AgentRunKit
import Foundation

/// Sampling limits for the on-device model, shared by the journal helper and local chat.
enum LocalGeneration {
    static func requestContext(maxTokens: Int) -> RequestContext {
        RequestContext(extraFields: [
            "temperature": .double(0.7),
            "top_p": .double(0.8),
            "max_tokens": .int(maxTokens),
            "repetition_penalty": .double(1.1)
        ])
    }
}

enum StreamBridge {
    /// Forwards `.content` text only. Ending the returned stream (e.g. cancelling its consumer)
    /// cancels the pump, which ends iteration of `upstream` and so the model call.
    static func contentOnly(_ upstream: AsyncThrowingStream<StreamDelta, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await delta in upstream {
                        if case let .content(text) = delta {
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
