import Foundation
import PocketAgentCore
import Translation

/// On-device translation with Apple's Translation framework, for language pairs already installed.
/// Sessions are made without a view (`init(installedSource:target:)`, iOS 26+) and kept per pair.
/// Downloading a pair needs a view: `.translationTask` + `prepareTranslation()` (see the validation screen).
final class AppleTranslator: Translating, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: TranslationSession] = [:]

    /// True when the pair is installed on this device (so `translate` can run without a download).
    static func isInstalled(from source: String, to target: String) async -> Bool {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        return status == .installed
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let session = try session(from: source, to: target)
        return try await session.translate(text).targetText
    }

    private func session(from source: String, to target: String) throws -> TranslationSession {
        let key = source + ">" + target
        if let existing = lock.withLock({ sessions[key] }) { return existing }
        let made = try TranslationSession(
            installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        lock.withLock { sessions[key] = made }
        return made
    }
}
