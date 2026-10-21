import Foundation

/// The on-device model the journal runs on. There is no Claude case: the journal never leaves the device.
public enum JournalBackend: Sendable, Equatable {
    case appleLocal
    case mlxLocal
}

/// User decision 2026-10-22: Apple when it is chosen in Settings and usable on this device,
/// otherwise the downloaded model (also when Claude is chosen).
public enum JournalModelRule {
    public static func backend(choice: ModelChoice, appleUnavailable: ModelUnavailableReason?) -> JournalBackend {
        choice == .appleLocal && appleUnavailable == nil ? .appleLocal : .mlxLocal
    }

    /// Asks the availability checker only when Apple is chosen.
    public static func backend(choice: ModelChoice, availability: any ModelAvailabilityChecking) -> JournalBackend {
        guard choice == .appleLocal else { return .mlxLocal }
        return backend(choice: choice, appleUnavailable: availability.appleLocalUnavailableReason())
    }

    /// Characters of journal context for "ask the journal". Apple's context window is small (~4096 tokens).
    public static func contextCharacterBudget(for backend: JournalBackend) -> Int {
        switch backend {
        case .appleLocal: 1500
        case .mlxLocal: 3000
        }
    }
}
