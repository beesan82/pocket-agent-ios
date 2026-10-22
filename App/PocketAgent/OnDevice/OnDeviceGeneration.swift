import AgentRunKit
import FoundationModels

/// An on-device model as a Foundation Models provider: `SystemLanguageModel` or `MLXLanguageModel`.
typealias OnDeviceLanguageModel = FoundationModels.LanguageModel & Sendable

/// The journal / meeting request settings (`LocalGeneration` extra fields) that Foundation Models
/// can express. `top_p` and `repetition_penalty` have no Foundation Models option and are dropped.
struct OnDeviceGeneration: Equatable {
    var maxTokens: Int?
    var temperature: Double?

    static func from(_ context: RequestContext?) -> OnDeviceGeneration {
        var generation = OnDeviceGeneration(maxTokens: nil, temperature: nil)
        guard let fields = context?.extraFields else { return generation }
        if case let .int(value)? = fields["max_tokens"] { generation.maxTokens = value }
        if case let .double(value)? = fields["temperature"] { generation.temperature = value }
        return generation
    }

    var options: GenerationOptions {
        GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
    }
}

/// A fresh session over any on-device model (opens the existential for the generic initializer).
func makeOnDeviceSession(
    _ model: any OnDeviceLanguageModel, tools: [any FoundationModels.Tool] = [], instructions: String
) -> LanguageModelSession {
    makeSession(model, tools: tools, instructions: instructions)
}

private func makeSession<M: OnDeviceLanguageModel>(
    _ model: M, tools: [any FoundationModels.Tool], instructions: String
) -> LanguageModelSession {
    LanguageModelSession(model: model, tools: tools, instructions: instructions)
}
