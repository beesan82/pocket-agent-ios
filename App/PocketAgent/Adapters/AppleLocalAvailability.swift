import FoundationModels
import PocketAgentCore

/// FR-03: checks Apple's on-device model before any run. Never falls back to Claude.
struct AppleLocalAvailability: ModelAvailabilityChecking {
    func appleLocalUnavailableReason() -> ModelUnavailableReason? {
        Self.reason(for: SystemLanguageModel.default.availability)
    }

    static func reason(for availability: SystemLanguageModel.Availability) -> ModelUnavailableReason? {
        switch availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            .modelNotReady
        case let .unavailable(other):
            .unknown(String(describing: other))
        @unknown default:
            .unknown(String(describing: availability))
        }
    }
}
