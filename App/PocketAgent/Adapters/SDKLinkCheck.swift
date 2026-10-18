import AgentRunKit
import AgentRunKitFoundationModels
import AgentRunKitMLX
import Foundation

/// Phase 0-3: proves AgentRunKit v6.1.0 links for iOS.
/// Only references symbols confirmed in the v6.1.0 sources:
/// - `AnthropicClient.anthropicBaseURL` (LLM/Providers/Anthropic/AnthropicClient.swift)
/// - `FoundationModelsClient<C: ToolContext>` (AgentRunKitFoundationModels/FoundationModelsClient.swift)
/// - `MLXClient` (AgentRunKitMLX/MLXClient.swift): compile/link only, never run on the simulator
/// - `EmptyContext` (Tools/ToolContext.swift)
enum SDKLinkCheck {
    static let agentRunKitLinked = true

    static var anthropicHost: String {
        AnthropicClient.anthropicBaseURL.host() ?? "-"
    }

    static var foundationModelsClientTypeName: String {
        String(describing: FoundationModelsClient<EmptyContext>.self)
    }

    static var mlxClientTypeName: String {
        String(describing: MLXClient.self)
    }
}
