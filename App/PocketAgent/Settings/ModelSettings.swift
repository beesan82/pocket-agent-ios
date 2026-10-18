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
    }

    @ObservationIgnored private let defaults: UserDefaults

    var choice: ModelChoice {
        didSet { defaults.set(choice.rawValue, forKey: Key.choice) }
    }

    var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: Key.claudeModel) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.string(forKey: Key.choice).flatMap(ModelChoice.init(rawValue:)) ?? .claude
        claudeModel = defaults.string(forKey: Key.claudeModel) ?? ClaudeAdapter.defaultModel
    }
}
