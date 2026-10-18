import AgentRunKit
import AgentRunKitFoundationModels
import PocketAgentCore
import PocketAgentRuntime

// RED stub
enum LLMClientFactory {
    static func resolver(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        claudeModel: String
    ) -> ModelBackendResolver<any LLMClient> {
        ModelBackendResolver(
            credentials: credentials,
            availability: availability,
            makeClaude: { _ in FoundationModelsClient<EmptyContext>(context: EmptyContext()) },
            makeAppleLocal: { try ClaudeAdapter.makeClient(apiKey: "x", model: claudeModel) }
        )
    }
}
