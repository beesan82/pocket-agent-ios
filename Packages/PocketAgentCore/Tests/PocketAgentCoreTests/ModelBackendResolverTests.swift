import Foundation
import Testing
@testable import PocketAgentCore

private final class SpyCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var failRead: Bool
    private var _reads = 0

    init(key: String?, failRead: Bool = false) {
        self.key = key
        self.failRead = failRead
    }

    var reads: Int { lock.withLock { _reads } }

    struct ReadFailure: Error {}

    func readAPIKey() throws -> String? {
        try lock.withLock {
            _reads += 1
            if failRead { throw ReadFailure() }
            return key
        }
    }

    func saveAPIKey(_ apiKey: String) throws { lock.withLock { key = apiKey } }
    func deleteAPIKey() throws { lock.withLock { key = nil } }
}

private final class StubAvailability: ModelAvailabilityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let reason: ModelUnavailableReason?
    private var _checks = 0

    init(_ reason: ModelUnavailableReason?) { self.reason = reason }

    var checks: Int { lock.withLock { _checks } }

    func appleLocalUnavailableReason() -> ModelUnavailableReason? {
        lock.withLock { _checks += 1 }
        return reason
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var count: Int { lock.withLock { values.count } }
    var last: String? { lock.withLock { values.last } }
    func record(_ value: String) { lock.withLock { values.append(value) } }
}

private enum Backend: Equatable {
    case claude(String)
    case appleLocal
}

private struct FactoryFailure: Error {}

private func makeResolver(
    store: SpyCredentialStore,
    availability: StubAvailability,
    claudeCalls: Counter,
    appleCalls: Counter,
    claudeThrows: Bool = false
) -> ModelBackendResolver<Backend> {
    ModelBackendResolver(
        credentials: store,
        availability: availability,
        makeClaude: { key in
            claudeCalls.record(key)
            if claudeThrows { throw FactoryFailure() }
            return .claude(key)
        },
        makeAppleLocal: {
            appleCalls.record("apple")
            return .appleLocal
        }
    )
}

struct ModelBackendResolverTests {
    // AT-14: choosing on-device must not touch any Claude credential or client.
    @Test func appleLocalNeverReadsKeyOrBuildsClaude() throws {
        let store = SpyCredentialStore(key: "test-key")
        let claude = Counter(), apple = Counter()
        let resolver = makeResolver(store: store, availability: StubAvailability(nil), claudeCalls: claude, appleCalls: apple)

        let backend = try resolver.resolve(.appleLocal).get()

        #expect(backend == .appleLocal)
        #expect(store.reads == 0)
        #expect(claude.count == 0)
        #expect(apple.count == 1)
    }

    // AT-03: unavailable on-device model reports why; never falls back to Claude.
    @Test(arguments: [
        ModelUnavailableReason.deviceNotEligible,
        .appleIntelligenceNotEnabled,
        .modelNotReady,
        .unsupportedOS
    ])
    func appleLocalUnavailableDoesNotFallBackToClaude(reason: ModelUnavailableReason) {
        let store = SpyCredentialStore(key: "test-key")
        let claude = Counter(), apple = Counter()
        let resolver = makeResolver(store: store, availability: StubAvailability(reason), claudeCalls: claude, appleCalls: apple)

        let result = resolver.resolve(.appleLocal)

        #expect(result == .failure(.unavailable(reason)))
        #expect(store.reads == 0)
        #expect(claude.count == 0)
        #expect(apple.count == 0)
    }

    @Test(arguments: [nil, "", "  \n"] as [String?])
    func claudeWithoutKeyIsMissingAPIKey(key: String?) {
        let claude = Counter(), apple = Counter()
        let resolver = makeResolver(
            store: SpyCredentialStore(key: key), availability: StubAvailability(nil),
            claudeCalls: claude, appleCalls: apple
        )

        #expect(resolver.resolve(.claude) == .failure(.unavailable(.missingAPIKey)))
        #expect(claude.count == 0)
    }

    @Test func claudeTrimsKey() throws {
        let claude = Counter(), apple = Counter()
        let resolver = makeResolver(
            store: SpyCredentialStore(key: "  test-key \n"), availability: StubAvailability(nil),
            claudeCalls: claude, appleCalls: apple
        )

        #expect(try resolver.resolve(.claude).get() == .claude("test-key"))
        #expect(claude.last == "test-key")
        #expect(apple.count == 0)
    }

    @Test func claudeNeverChecksAppleAvailability() {
        let availability = StubAvailability(.deviceNotEligible)
        let resolver = makeResolver(
            store: SpyCredentialStore(key: "test-key"), availability: availability,
            claudeCalls: Counter(), appleCalls: Counter()
        )

        #expect(resolver.resolve(.claude) == .success(.claude("test-key")))
        #expect(availability.checks == 0)
    }

    @Test func claudeFactoryThrowIsClientCreationFailed() {
        let resolver = makeResolver(
            store: SpyCredentialStore(key: "test-key"), availability: StubAvailability(nil),
            claudeCalls: Counter(), appleCalls: Counter(), claudeThrows: true
        )

        #expect(resolver.resolve(.claude) == .failure(.clientCreationFailed))
    }

    @Test func credentialReadErrorIsReported() {
        let resolver = makeResolver(
            store: SpyCredentialStore(key: "test-key", failRead: true), availability: StubAvailability(nil),
            claudeCalls: Counter(), appleCalls: Counter()
        )

        #expect(resolver.resolve(.claude) == .failure(.credentialReadFailed))
    }

    @Test(arguments: [
        ModelUnavailableReason.missingAPIKey, .deviceNotEligible, .appleIntelligenceNotEnabled,
        .modelNotReady, .unsupportedOS, .unknown("x")
    ])
    func everyReasonExplainsItself(reason: ModelUnavailableReason) {
        #expect(!reason.userMessage.isEmpty)
    }

    @Test func choicePersistsAsStableRawValues() {
        #expect(ModelChoice.claude.rawValue == "claude")
        #expect(ModelChoice.appleLocal.rawValue == "appleLocal")
        #expect(ModelChoice(rawValue: "appleLocal") == .appleLocal)
    }
}
