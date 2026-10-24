import FoundationModels
import PocketAgentCore

/// The on-device models (Apple and the downloaded model) as the chat sees them (injected so tests
/// use a fake). Never asked about `.claude`.
@MainActor
protocol OnDeviceModelAccess {
    /// Why `choice` cannot answer now; nil or `.modelLoading` means `runner(for:)` may be tried.
    func reason(for choice: ModelChoice) -> ModelUnavailableReason?
    /// A turn runner on the model, loading the downloaded model first when needed; nil when it cannot be loaded.
    func runner(for choice: ModelChoice) async -> (any OnDeviceTurnRunner)?
}

/// Production access: Apple's model, or the same MLX store and runtime the journal uses.
@MainActor
struct LiveOnDeviceModelAccess: OnDeviceModelAccess {
    let store: MLXModelStore
    let runtime: MLXRuntime
    let availability: any ModelAvailabilityChecking

    func reason(for choice: ModelChoice) -> ModelUnavailableReason? {
        switch choice {
        case .appleLocal: availability.appleLocalUnavailableReason()
        case .mlxLocal: JournalModelAccess.reason(store: store, runtime: runtime)
        case .claude: nil
        }
    }

    func runner(for choice: ModelChoice) async -> (any OnDeviceTurnRunner)? {
        switch choice {
        case .appleLocal:
            return FoundationModelsTurnRunner(model: SystemLanguageModel.default)
        case .mlxLocal:
            // Same load rules as the journal: never loads a model that is not downloaded.
            guard await JournalModelAccess.client(store: store, runtime: runtime) != nil,
                  let model = runtime.languageModel
            else { return nil }
            return FoundationModelsTurnRunner(model: model)
        case .claude:
            return nil
        }
    }
}
