import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

@MainActor
struct ModelSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "ModelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToClaudeWithDefaultModel() {
        let settings = ModelSettings(defaults: makeDefaults())

        #expect(settings.choice == .claude)
        #expect(settings.claudeModel == "claude-sonnet-5-5")
    }

    @Test func choiceAndModelPersist() {
        let defaults = makeDefaults()
        let settings = ModelSettings(defaults: defaults)

        settings.choice = .appleLocal
        settings.claudeModel = "claude-opus-5-5"
        let reloaded = ModelSettings(defaults: defaults)

        #expect(reloaded.choice == .appleLocal)
        #expect(reloaded.claudeModel == "claude-opus-5-5")
    }

    // The API key must never live in UserDefaults.
    @Test func nothingKeyLikeIsWrittenToDefaults() {
        let defaults = makeDefaults()
        let settings = ModelSettings(defaults: defaults)
        settings.choice = .claude

        let stored = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("pocketagent.") }
        #expect(Set(stored).isSubset(of: ["pocketagent.modelChoice", "pocketagent.claudeModel"]))
    }
}
