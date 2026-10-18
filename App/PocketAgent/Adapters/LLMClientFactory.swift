import AgentRunKit
import AgentRunKitFoundationModels
import PocketAgentCore
import PocketAgentRuntime

/// Wires the SDK clients into Core's resolver. Clients are returned unwrapped (see `ClaudeAdapter`).
enum LLMClientFactory {
    /// `appleLocalTools` are run by the Foundation Models session itself, bypassing
    /// AgentRunner's approval policy: they must come from `ToolApprovalGate.wrap` (ADR-009).
    static func resolver(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        claudeModel: String,
        appleLocalTools: [any AnyTool<EmptyContext>] = []
    ) -> ModelBackendResolver<any LLMClient> {
        ModelBackendResolver(
            credentials: credentials,
            availability: availability,
            makeClaude: { key in try ClaudeAdapter.makeClient(apiKey: key, model: claudeModel) },
            makeAppleLocal: {
                FoundationModelsClient<EmptyContext>(tools: appleLocalTools, context: EmptyContext())
            }
        )
    }
}
