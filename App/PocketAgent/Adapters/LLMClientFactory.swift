import AgentRunKit
import FoundationModels
import PocketAgentCore
import PocketAgentRuntime

/// Wires the SDK clients into Core's resolver. Clients are returned unwrapped (see `ClaudeAdapter`).
/// The chat only resolves Claude here; on-device chat runs through `OnDeviceModelAccess`.
/// `.appleLocal` still resolves to a tool-less Foundation Models text client so the resolver keeps
/// its AT-03 / AT-14 guarantees (availability checked first, the key never read). Test-only
/// guarantee: do not route on-device chat back through this client (it has no tools).
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
            makeAppleLocal: { FoundationModelsTextClient(model: SystemLanguageModel.default) }
        )
    }
}
