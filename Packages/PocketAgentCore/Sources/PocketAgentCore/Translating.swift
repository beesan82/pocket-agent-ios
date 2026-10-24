import Foundation

/// On-device translation of one utterance ("ja" ⇄ "en"). The app's implementation uses Apple's
/// Translation framework; nothing leaves the device.
public protocol Translating: Sendable {
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}
