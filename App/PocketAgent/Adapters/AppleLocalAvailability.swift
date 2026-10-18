import FoundationModels
import PocketAgentCore

// RED stub
struct AppleLocalAvailability: ModelAvailabilityChecking {
    func appleLocalUnavailableReason() -> ModelUnavailableReason? { nil }

    static func reason(for _: SystemLanguageModel.Availability) -> ModelUnavailableReason? { .unknown("") }
}
