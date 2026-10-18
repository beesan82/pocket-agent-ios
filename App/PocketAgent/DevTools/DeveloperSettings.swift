import Foundation
import Observation

/// Developer-mode switch and upload target. The GitHub token is never stored here (Keychain only).
@MainActor
@Observable
final class DeveloperSettings {
    private enum Key {
        static let enabled = "pocketagent.developerMode"
        static let repository = "pocketagent.measurementRepo"
    }

    static let defaultRepository = "beesan82/pocket-agent-measurements"

    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool
    var repository: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = false
        repository = Self.defaultRepository
    }

    /// Exactly `owner/name`, both parts `[A-Za-z0-9._-]+`; "." and ".." are rejected (path traversal).
    nonisolated static func isValidRepository(_ value: String) -> Bool {
        false
    }
}
