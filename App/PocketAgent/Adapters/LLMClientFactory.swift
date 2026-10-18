import AgentRunKit
import AgentRunKitFoundationModels
import PocketAgentCore
import PocketAgentRuntime

/// Wires the SDK clients into Core's resolver. Clients are returned unwrapped (see `ClaudeAdapter`).
enum LLMClientFactory {
    static func resolver(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        claudeModel: String
    ) -> ModelBackendResolver<any LLMClient> {
        ModelBackendResolver(
            credentials: credentials,
            availability: availability,
            makeClaude: { key in try ClaudeAdapter.makeClient(apiKey: key, model: claudeModel) },
            // No tools: FoundationModelsClient runs tools inside its own session,
            // bypassing AgentRunner's approval gate (ADR-009).
            makeAppleLocal: { FoundationModelsClient<EmptyContext>(context: EmptyContext()) }
        )
    }
}
