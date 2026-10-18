import FoundationModels
import PocketAgentCore
import Testing
@testable import PocketAgent

// AT-03 (Unit part): every Foundation Models state maps to a shown reason.
struct AppleLocalAvailabilityTests {
    @Test func availableHasNoReason() {
        #expect(AppleLocalAvailability.reason(for: .available) == nil)
    }

    @Test func deviceNotEligible() {
        #expect(AppleLocalAvailability.reason(for: .unavailable(.deviceNotEligible)) == .deviceNotEligible)
    }

    @Test func appleIntelligenceNotEnabled() {
        #expect(
            AppleLocalAvailability.reason(for: .unavailable(.appleIntelligenceNotEnabled))
                == .appleIntelligenceNotEnabled
        )
    }

    @Test func modelNotReady() {
        #expect(AppleLocalAvailability.reason(for: .unavailable(.modelNotReady)) == .modelNotReady)
    }

    @Test func liveCheckDoesNotCrash() {
        // Simulator / CI result varies; only the call path is checked here.
        _ = AppleLocalAvailability().appleLocalUnavailableReason()
    }
}
