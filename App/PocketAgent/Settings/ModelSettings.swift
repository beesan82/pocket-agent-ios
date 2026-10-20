import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// Non-secret model settings in UserDefaults. The API key is never stored here.
@MainActor
@Observable
final class ModelSettings {
    private enum Key {
        static let choice = "pocketagent.modelChoice"
        static let claudeModel = "pocketagent.claudeModel"
        static let defaultModelMigrated = "pocketagent.defaultModelMigrated"
    }

    /// The app's default: the downloaded on-device model (user decision 2026-10-21).
    static let defaultChoice = ModelChoice.mlxLocal

    @ObservationIgnored private let defaults: UserDefaults

    var choice: ModelChoice {
        didSet { defaults.set(choice.rawValue, forKey: Key.choice) }
    }

    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Key.claudeModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.string(forKey: Key.choice).flatMap(ModelChoice.init(rawValue:)) ?? Self.defaultChoice
        claudeModel = defaults.string(forKey: Key.claudeModel) ?? ClaudeAdapter.defaultModel
    }

    /// Once per install: a Claude choice, saved or implied by the old default (nothing saved),
    /// stays on Claude only when an API key is saved; otherwise it moves to the new default.
    /// Only checks whether a key exists (never builds a client). A failed key read leaves the
    /// flag unset so the next launch tries again.
    func migrateDefaultModelIfNeeded(credentials: any CredentialStore) {
        guard !defaults.bool(forKey: Key.defaultModelMigrated) else { return }
        let stored = defaults.string(forKey: Key.choice)
        if stored == nil || stored == ModelChoice.claude.rawValue {
            let key: String?
            do {
                key = try credentials.readAPIKey()
            } catch {
                return
            }
            // Assigned either way so the result is saved, not left to the default.
            choice = (key?.isEmpty ?? true) ? Self.defaultChoice : .claude
        }
        defaults.set(true, forKey: Key.defaultModelMigrated)
    }
}
