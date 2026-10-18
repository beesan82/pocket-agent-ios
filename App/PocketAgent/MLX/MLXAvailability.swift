import PocketAgentCore

/// Why the MLX model cannot answer right now (nil = usable).
enum MLXAvailability {
    static func reason(state: MLXRuntime.State, status: MLXModelStore.Status) -> ModelUnavailableReason? {
        #if targetEnvironment(simulator)
        return .simulatorUnsupported
        #else
        return deviceReason(state: state, status: status)
        #endif
    }

    /// Device mapping, separate so the simulator tests can cover it.
    /// `.idle`/`.failed` with the model downloaded returns nil: there is no client yet,
    /// so callers must `load()` first (they never use the model without loading).
    static func deviceReason(state: MLXRuntime.State, status: MLXModelStore.Status) -> ModelUnavailableReason? {
        switch state {
        case .loaded:
            nil
        case .loading:
            .modelLoading
        case .unloadedForMemory:
            .unloadedForMemory
        case .idle, .failed:
            status == .downloaded ? nil : .modelNotDownloaded
        }
    }
}
