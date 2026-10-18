import AgentRunKit
import PocketAgentCore
import Testing
@testable import PocketAgent

struct LLMClientFactoryTests {
    // AT-14 (Unit part): on-device choice never reads the Claude key or builds AnthropicClient.
    @Test func appleLocalBuildsFoundationModelsClientWithoutTouchingKey() throws {
        let store = SpyCredentialStore(key: "test-key")
        let resolver = LLMClientFactory.resolver(
            credentials: store, availability: FixedAvailability(reason: nil), claudeModel: "claude-sonnet-5-5"
        )

        let client = try resolver.resolve(.appleLocal).get()

        #expect(client.providerIdentifier == .foundationModels)
        #expect(!(client is AnthropicClient))
        #expect(store.reads == 0)
    }

    // AT-03 / AT-14: unavailable on-device model is reported, not replaced by Claude.
    @Test func unavailableAppleLocalNeverFallsBackToClaude() {
        let store = SpyCredentialStore(key: "test-key")
        let resolver = LLMClientFactory.resolver(
            credentials: store, availability: FixedAvailability(reason: .appleIntelligenceNotEnabled),
            claudeModel: "claude-sonnet-5-5"
        )

        let result = resolver.resolve(.appleLocal)

        guard case .failure(.unavailable(.appleIntelligenceNotEnabled)) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(store.reads == 0)
    }

    @Test func claudeBuildsAnthropicClientWithChosenModel() throws {
        let resolver = LLMClientFactory.resolver(
            credentials: SpyCredentialStore(key: "test-key"), availability: FixedAvailability(reason: nil),
            claudeModel: "claude-opus-5-5"
        )

        let client = try #require(try resolver.resolve(.claude).get() as? AnthropicClient)

        #expect(client.providerIdentifier == .anthropic)
        #expect(client.modelIdentifier == "claude-opus-5-5")
    }

    // AT-04 (Unit part): switching back and forth resolves the matching provider each time.
    @Test func switchingChoiceSwitchesProvider() throws {
        let resolver = LLMClientFactory.resolver(
            credentials: SpyCredentialStore(key: "test-key"), availability: FixedAvailability(reason: nil),
            claudeModel: "claude-sonnet-5-5"
        )

        let providers = try [ModelChoice.claude, .appleLocal, .claude].map {
            try resolver.resolve($0).get().providerIdentifier
        }

        #expect(providers == [.anthropic, .foundationModels, .anthropic])
    }
}
