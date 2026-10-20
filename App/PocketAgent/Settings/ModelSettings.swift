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

    /// Once per install: a saved Claude choice without a saved API key moves to the new default.
    /// Only checks whether a key exists (never builds a client). A failed key read leaves the
    /// flag unset so the next launch tries again.
    func migrateDefaultModelIfNeeded(credentials: any CredentialStore) {
        guard !defaults.bool(forKey: Key.defaultModelMigrated) else { return }
        if defaults.string(forKey: Key.choice) == ModelChoice.claude.rawValue {
            let key: String?
            do {
                key = try credentials.readAPIKey()
            } catch {
                return
            }
            if key?.isEmpty ?? true {
                choice = Self.defaultChoice
            }
        }
        defaults.set(true, forKey: Key.defaultModelMigrated)
    }
}
