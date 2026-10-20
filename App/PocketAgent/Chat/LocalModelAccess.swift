import AgentRunKit
import PocketAgentCore

/// The downloaded on-device model as the chat sees it (injected so tests use a fake).
@MainActor
protocol LocalModelAccess {
    /// Why the model cannot answer now; nil or `.modelLoading` means `client()` may be tried.
    func reason() -> ModelUnavailableReason?
    /// The loaded client, loading the selected model first when needed; nil when it cannot be loaded.
    func client() async -> (any LLMClient)?
}

/// Production access: the same store and runtime the journal uses.
@MainActor
struct MLXLocalModelAccess: LocalModelAccess {
    let store: MLXModelStore
    let runtime: MLXRuntime

    func reason() -> ModelUnavailableReason? {
        JournalModelAccess.reason(store: store, runtime: runtime)
    }

    func client() async -> (any LLMClient)? {
        await JournalModelAccess.client(store: store, runtime: runtime)
    }
}
