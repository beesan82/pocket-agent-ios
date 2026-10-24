import AgentRunKit
import Foundation
import FoundationModels

/// One on-device chat turn. Injected so `ChatSession` tests run without a model.
protocol OnDeviceTurnRunner: Sendable {
    /// Reply text as it grows (new suffixes). `tools` are the gated, recorded note tools; the
    /// model calls them natively. Ending the consumer cancels the turn.
    func run(instructions: String, prompt: String, tools: [any AnyTool<EmptyContext>]) -> AsyncThrowingStream<String, Error>
}

/// A fresh `LanguageModelSession` per turn, greedy, with the note tools (spike: a small model
/// stops calling tools after the first turn of a kept session, and samples off-format text).
struct FoundationModelsTurnRunner: OnDeviceTurnRunner {
    static let maxResponseTokens = 512

    let model: any OnDeviceLanguageModel

    func run(instructions: String, prompt: String, tools: [any AnyTool<EmptyContext>]) -> AsyncThrowingStream<String, Error> {
        let model = model
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: Self.maxResponseTokens)
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    let session = makeOnDeviceSession(model, tools: FMNoteTools.make(tools), instructions: instructions)
                    var sent = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let delta = FoundationModelsTextClient.delta(from: sent, to: snapshot.content)
                        if !delta.isEmpty { continuation.yield(delta) }
                        sent = snapshot.content
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
