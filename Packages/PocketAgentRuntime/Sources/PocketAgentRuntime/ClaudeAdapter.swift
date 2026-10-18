import AgentRunKit
import Foundation

/// Builds the Claude Messages API client (AgentRunKit `AnthropicClient`).
///
/// Returns the SDK type itself, never a wrapper: AgentRunKit 6.1.0 ends a run on a
/// text-only reply only for its own `ContentOnlyTerminatingClient` types, so a
/// wrapper would loop until the step limit.
public enum ClaudeAdapter {
    public enum ConfigurationError: Error, Equatable {
        case emptyAPIKey
        case emptyModel
    }

    public static let defaultModel = "claude-sonnet-5-5"
    public static let defaultMaxTokens = 1024

    /// The key is passed straight to the SDK (sent only as `x-api-key`); never log it.
    public static func makeClient(
        apiKey: String,
        model: String,
        maxTokens: Int = defaultMaxTokens,
        session: URLSession = .shared
    ) throws -> AnthropicClient {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ConfigurationError.emptyAPIKey }
        guard !model.isEmpty else { throw ConfigurationError.emptyModel }
        return try AnthropicClient(apiKey: key, model: model, maxTokens: maxTokens, session: session)
    }
}
