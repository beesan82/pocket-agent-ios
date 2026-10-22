import Testing
@testable import PocketAgent

struct SDKLinkCheckTests {
    @Test func anthropicClientUsesOfficialHost() {
        #expect(SDKLinkCheck.anthropicHost == "api.anthropic.com")
    }

    @Test func appleOnDeviceModelIsLinked() {
        #expect(SDKLinkCheck.appleModelTypeName.contains("SystemLanguageModel"))
    }

    @Test func mlxModelIsLinked() {
        #expect(SDKLinkCheck.mlxModelTypeName.contains("MLXLanguageModel"))
    }
}
