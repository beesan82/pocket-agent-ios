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

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    var repository: String {
        didSet { defaults.set(repository, forKey: Key.repository) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        repository = defaults.string(forKey: Key.repository) ?? Self.defaultRepository
    }

    /// Exactly `owner/name`, both parts `[A-Za-z0-9._-]+`; "." and ".." are rejected (path traversal).
    nonisolated static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { scalar in
                    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
                }
        }
    }
}
