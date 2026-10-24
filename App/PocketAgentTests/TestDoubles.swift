import Foundation
import PocketAgentCore

final class SpyCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var _reads = 0
    private var _deletes = 0

    init(key: String?) { self.key = key }

    var reads: Int { lock.withLock { _reads } }
    var deletes: Int { lock.withLock { _deletes } }

    func readAPIKey() throws -> String? {
        lock.withLock {
            _reads += 1
            return key
        }
    }

    func saveAPIKey(_ apiKey: String) throws { lock.withLock { key = apiKey } }
    func deleteAPIKey() throws {
        lock.withLock {
            _deletes += 1
            key = nil
        }
    }
}

struct FixedAvailability: ModelAvailabilityChecking {
    let reason: ModelUnavailableReason?
    func appleLocalUnavailableReason() -> ModelUnavailableReason? { reason }
}

/// A memory store whose every call fails, for the "memory unavailable" path.
struct ThrowingMemoryStore: MemoryStore {
    struct Failure: Error {}

    func add(_: String) async throws -> Note { throw Failure() }
    func all() async throws -> [Note] { throw Failure() }
    func search(_: String) async throws -> [Note] { throw Failure() }
    func note(id _: UUID) async throws -> Note? { throw Failure() }
    func update(id _: UUID, text _: String) async throws -> Note? { throw Failure() }
    func delete(id _: UUID) async throws -> Bool { throw Failure() }
    func deleteAll() async throws { throw Failure() }
    func allMemory() async throws -> [MemoryItem] { throw Failure() }
    func searchMemory(_: String) async throws -> [MemoryItem] { throw Failure() }
}

/// Collects the measurement log lines a `ChatSession` writes.
@MainActor
final class LogLines {
    private(set) var entries: [String] = []

    func append(_ line: String) {
        entries.append(line)
    }
}

/// A journal store whose every call fails, for the "journal lookup failed" path.
struct ThrowingJournalStore: JournalStore {
    struct Failure: Error {}

    func add(_: NewJournalEntry) async throws -> JournalEntry { throw Failure() }
    func all() async throws -> [JournalEntry] { throw Failure() }
    func search(_: String) async throws -> [JournalEntry] { throw Failure() }
    func entries(in _: DateInterval) async throws -> [JournalEntry] { throw Failure() }
    func recent(limit _: Int) async throws -> [JournalEntry] { throw Failure() }
    func entry(id _: UUID) async throws -> JournalEntry? { throw Failure() }
    func update(id _: UUID, body _: String) async throws -> JournalEntry? { throw Failure() }
    func delete(id _: UUID) async throws -> Bool { throw Failure() }
    func deleteAll() async throws { throw Failure() }
}
