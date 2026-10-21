import Foundation
import Testing
@testable import PocketAgentCore

private final class CountingAvailability: ModelAvailabilityChecking, @unchecked Sendable {
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

/// User decision 2026-10-22: Apple when chosen and usable, otherwise the downloaded model; never Claude.
struct JournalModelRuleTests {
    @Test func appleChosenAndAvailableUsesApple() {
        #expect(JournalModelRule.backend(choice: .appleLocal, appleUnavailable: nil) == .appleLocal)
    }

    @Test func appleChosenButUnavailableUsesDownloaded() {
        #expect(JournalModelRule.backend(choice: .appleLocal, appleUnavailable: .deviceNotEligible) == .mlxLocal)
        #expect(JournalModelRule.backend(choice: .appleLocal, appleUnavailable: .modelNotReady) == .mlxLocal)
    }

    @Test func claudeChosenUsesDownloadedNeverClaude() {
        #expect(JournalModelRule.backend(choice: .claude, appleUnavailable: nil) == .mlxLocal)
        #expect(JournalModelRule.backend(choice: .claude, appleUnavailable: .deviceNotEligible) == .mlxLocal)
    }

    @Test func mlxChosenUsesDownloaded() {
        #expect(JournalModelRule.backend(choice: .mlxLocal, appleUnavailable: nil) == .mlxLocal)
    }

    @Test func availabilityIsCheckedOnlyWhenAppleIsChosen() {
        let apple = CountingAvailability(nil)
        #expect(JournalModelRule.backend(choice: .appleLocal, availability: apple) == .appleLocal)
        #expect(apple.checks == 1)

        let other = CountingAvailability(nil)
        #expect(JournalModelRule.backend(choice: .claude, availability: other) == .mlxLocal)
        #expect(JournalModelRule.backend(choice: .mlxLocal, availability: other) == .mlxLocal)
        #expect(other.checks == 0)
    }

    // Apple's context window is small (~4096 tokens).
    @Test func appleGetsTheSmallerContextBudget() {
        #expect(JournalModelRule.contextCharacterBudget(for: .appleLocal) == 1500)
        #expect(JournalModelRule.contextCharacterBudget(for: .mlxLocal) == 3000)
    }
}
