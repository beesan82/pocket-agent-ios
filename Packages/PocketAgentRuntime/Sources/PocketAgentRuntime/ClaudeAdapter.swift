import AgentRunKit
import Foundation

// RED stub: signatures only. Behaviour is deliberately wrong.
public enum ClaudeAdapter {
    public enum ConfigurationError: Error, Equatable {
        case emptyAPIKey
        case emptyModel
    }

    public static let defaultModel = ""
    public static let defaultMaxTokens = 0

    public static func makeClient(
        apiKey: String,
        model: String,
        maxTokens: Int = defaultMaxTokens,
        session: URLSession = .shared
    ) throws -> AnthropicClient {
        try AnthropicClient(apiKey: apiKey, model: model, maxTokens: maxTokens, session: session)
    }
}
