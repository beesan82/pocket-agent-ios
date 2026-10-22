import AgentRunKit
import Foundation
import FoundationModels
import MLXFoundationModels

/// Proves the SDKs link for iOS (compile/link only; nothing here runs a model):
/// - `AnthropicClient.anthropicBaseURL` (AgentRunKit fork 6.1.0-pocket.1, LLM/Providers/Anthropic)
/// - `SystemLanguageModel` (Foundation Models, iOS 27) and `MLXLanguageModel` (mlx-swift-lm 3.32.3
///   MLXFoundationModels): the two on-device providers
enum SDKLinkCheck {
    static let agentRunKitLinked = true

    static var anthropicHost: String {
        AnthropicClient.anthropicBaseURL.host() ?? "-"
    }

    static var appleModelTypeName: String {
        String(describing: SystemLanguageModel.self)
    }

    static var mlxModelTypeName: String {
        String(describing: MLXLanguageModel.self)
    }
}
