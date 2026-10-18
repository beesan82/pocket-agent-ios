import Foundation

// RED stub: signatures only. Behaviour is deliberately wrong.

public enum ModelChoice: String, Sendable, CaseIterable, Codable {
    case claude
    case appleLocal

    public var displayName: String { "" }
}

public enum ModelUnavailableReason: Sendable, Equatable {
    case missingAPIKey
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedOS
    case unknown(String)

    public var userMessage: String { "" }
}

public protocol CredentialStore: Sendable {
    func readAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

public protocol ModelAvailabilityChecking: Sendable {
    func appleLocalUnavailableReason() -> ModelUnavailableReason?
}

public enum ModelResolutionError: Error, Sendable, Equatable {
    case unavailable(ModelUnavailableReason)
    case credentialReadFailed
    case clientCreationFailed
}

public struct ModelBackendResolver<Backend>: Sendable {
    private let credentials: any CredentialStore
    private let availability: any ModelAvailabilityChecking
    private let makeClaude: @Sendable (String) throws -> Backend
    private let makeAppleLocal: @Sendable () throws -> Backend

    public init(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        makeClaude: @escaping @Sendable (String) throws -> Backend,
        makeAppleLocal: @escaping @Sendable () throws -> Backend
    ) {
        self.credentials = credentials
        self.availability = availability
        self.makeClaude = makeClaude
        self.makeAppleLocal = makeAppleLocal
    }

    public func resolve(_ choice: ModelChoice) -> Result<Backend, ModelResolutionError> {
        .failure(.clientCreationFailed)
    }
}
