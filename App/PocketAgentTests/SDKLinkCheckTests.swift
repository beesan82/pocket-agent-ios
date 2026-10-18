import Testing
@testable import PocketAgent

struct SDKLinkCheckTests {
    @Test func anthropicClientUsesOfficialHost() {
        #expect(SDKLinkCheck.anthropicHost == "api.anthropic.com")
    }

    @Test func foundationModelsClientIsLinked() {
        #expect(SDKLinkCheck.foundationModelsClientTypeName.contains("FoundationModelsClient"))
    }

    @Test func mlxClientIsLinked() {
        #expect(SDKLinkCheck.mlxClientTypeName.contains("MLXClient"))
    }
}
