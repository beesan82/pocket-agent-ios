import Foundation
import PocketAgentCore

final class SpyCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var _reads = 0

    init(key: String?) { self.key = key }

    var reads: Int { lock.withLock { _reads } }

    func readAPIKey() throws -> String? {
        lock.withLock {
            _reads += 1
            return key
        }
    }

    func saveAPIKey(_ apiKey: String) throws { lock.withLock { key = apiKey } }
    func deleteAPIKey() throws { lock.withLock { key = nil } }
}

struct FixedAvailability: ModelAvailabilityChecking {
    let reason: ModelUnavailableReason?
    func appleLocalUnavailableReason() -> ModelUnavailableReason? { reason }
}
