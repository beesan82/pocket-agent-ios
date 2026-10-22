import AgentRunKit
import Testing
@testable import PocketAgent

/// The journal/meeting request settings mapped onto Foundation Models options.
struct OnDeviceGenerationTests {
    @Test func readsMaxTokensAndTemperature() {
        let context = RequestContext(extraFields: [
            "temperature": .double(0.7),
            "top_p": .double(0.8),
            "max_tokens": .int(512),
            "repetition_penalty": .double(1.1)
        ])
        #expect(OnDeviceGeneration.from(context) == OnDeviceGeneration(maxTokens: 512, temperature: 0.7))
    }

    @Test func missingContextMeansProviderDefaults() {
        #expect(OnDeviceGeneration.from(nil) == OnDeviceGeneration(maxTokens: nil, temperature: nil))
    }
}
