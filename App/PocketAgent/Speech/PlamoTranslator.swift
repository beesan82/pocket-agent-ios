import Foundation
import PocketAgentCore

/// Runs one PFML3 prompt through a PLaMo 3 Translate runtime and returns the raw completion.
/// The runtime itself is not integrated yet (ADR-050); this is the seam it will plug into.
protocol PlamoInferenceEngine: Sendable {
    func generate(prompt: String) async throws -> String
}

enum PlamoTranslatorError: Error, Equatable {
    case invalidInput
    case runtimeUnavailable

    var userMessage: String {
        switch self {
        case .invalidInput:
            "翻訳できない文です"
        case .runtimeUnavailable:
            TranslationEngineResolver.UnavailableReason.plamoRuntimeUnavailable.userMessage
        }
    }
}

/// Default engine until a runtime is integrated: every call fails with `runtimeUnavailable`.
struct UnavailablePlamoEngine: PlamoInferenceEngine {
    func generate(prompt _: String) async throws -> String {
        throw PlamoTranslatorError.runtimeUnavailable
    }
}

enum PlamoRuntimeAvailability {
    /// False until a PLaMo runtime ships in the app (ADR-050). The official MLX 4-bit weights use the
    /// custom plamo3 architecture, which mlx-swift-lm does not register, and llama.cpp has no
    /// official iOS XCFramework that also carries the simulator slice CI needs.
    static let isAvailable = false
}

/// PLaMo 3 Translate behind `Translating`: builds the PFML3 prompt, cleans the completion.
final class PlamoTranslator: Translating, @unchecked Sendable {
    private let engine: any PlamoInferenceEngine

    init(engine: any PlamoInferenceEngine = UnavailablePlamoEngine()) {
        self.engine = engine
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard let prompt = PlamoPrompt.prompt(text: text, source: source, target: target) else {
            throw PlamoTranslatorError.invalidInput
        }
        return PlamoPrompt.cleanedOutput(try await engine.generate(prompt: prompt))
    }
}
