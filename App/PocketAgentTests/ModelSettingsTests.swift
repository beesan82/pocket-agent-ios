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

    // User decision 2026-10-21: the app starts on the downloaded model.
    @Test func defaultChoiceIsDownloadedModel() {
        let settings = ModelSettings(defaults: makeDefaults())

        #expect(settings.choice == .mlxLocal)
        #expect(settings.claudeModel == "claude-sonnet-5-5")
    }

    @Test func unknownRawValueFallsBackToDownloadedModel() {
        let defaults = makeDefaults()
        defaults.set("removedModel", forKey: "pocketagent.modelChoice")

        #expect(ModelSettings(defaults: defaults).choice == .mlxLocal)
    }

    @Test func migrationSwitchesClaudeWithoutKey() {
        let defaults = makeDefaults()
        defaults.set("claude", forKey: "pocketagent.modelChoice")
        let settings = ModelSettings(defaults: defaults)
        #expect(settings.choice == .claude)

        settings.migrateDefaultModelIfNeeded(credentials: SpyCredentialStore(key: nil))

        #expect(settings.choice == .mlxLocal)
        #expect(ModelSettings(defaults: defaults).choice == .mlxLocal)
    }

    // Nothing saved used to mean Claude (the old default): with a key, Claude is kept and saved.
    @Test func migrationKeepsClaudeForUnsetChoiceWithKey() {
        let defaults = makeDefaults()
        let settings = ModelSettings(defaults: defaults)
        let credentials = SpyCredentialStore(key: "test-key")

        settings.migrateDefaultModelIfNeeded(credentials: credentials)

        #expect(settings.choice == .claude)
        #expect(defaults.string(forKey: "pocketagent.modelChoice") == "claude")
        #expect(ModelSettings(defaults: defaults).choice == .claude)
        #expect(credentials.reads == 1)
    }

    @Test func freshInstallLandsOnDownloadedModel() {
        let defaults = makeDefaults()
        let settings = ModelSettings(defaults: defaults)

        settings.migrateDefaultModelIfNeeded(credentials: SpyCredentialStore(key: nil))

        #expect(settings.choice == .mlxLocal)
        #expect(ModelSettings(defaults: defaults).choice == .mlxLocal)
    }

    @Test func migrationKeepsClaudeWithKey() {
        let defaults = makeDefaults()
        defaults.set("claude", forKey: "pocketagent.modelChoice")
        let settings = ModelSettings(defaults: defaults)
        let credentials = SpyCredentialStore(key: "test-key")

        settings.migrateDefaultModelIfNeeded(credentials: credentials)

        #expect(settings.choice == .claude)
        #expect(credentials.reads == 1)
    }

    @Test func migrationRunsOnce() throws {
        let defaults = makeDefaults()
        defaults.set("claude", forKey: "pocketagent.modelChoice")
        let credentials = SpyCredentialStore(key: "test-key")
        ModelSettings(defaults: defaults).migrateDefaultModelIfNeeded(credentials: credentials)

        // The key is removed and Claude chosen again later: the migration never runs again.
        try credentials.deleteAPIKey()
        let later = ModelSettings(defaults: defaults)
        later.migrateDefaultModelIfNeeded(credentials: credentials)

        #expect(later.choice == .claude)
        #expect(credentials.reads == 1)
    }

    @Test func migrationLeavesOtherChoicesWithoutReadingKey() {
        let defaults = makeDefaults()
        defaults.set("appleLocal", forKey: "pocketagent.modelChoice")
        let settings = ModelSettings(defaults: defaults)
        let credentials = SpyCredentialStore(key: nil)

        settings.migrateDefaultModelIfNeeded(credentials: credentials)

        #expect(settings.choice == .appleLocal)
        #expect(credentials.reads == 0)
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
        settings.migrateDefaultModelIfNeeded(credentials: SpyCredentialStore(key: "test-key"))

        let stored = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("pocketagent.") }
        #expect(Set(stored).isSubset(of: [
            "pocketagent.modelChoice", "pocketagent.claudeModel", "pocketagent.defaultModelMigrated"
        ]))
    }
}
