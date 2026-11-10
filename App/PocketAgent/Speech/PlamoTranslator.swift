import Foundation
import PocketAgentCore

/// Runs one PFML3 prompt through a PLaMo 3 Translate runtime and returns the raw completion.
/// The app uses `LlamaCppPlamoEngine` (ADR-051); tests inject their own engines.
protocol PlamoInferenceEngine: Sendable {
    func generate(prompt: String) async throws -> String
}

enum PlamoTranslatorError: Error, Equatable {
    case invalidInput
    case modelNotDownloaded
    case inferenceFailed

    var userMessage: String {
        switch self {
        case .invalidInput:
            "翻訳できない文です"
        case .modelNotDownloaded:
            TranslationEngineResolver.UnavailableReason.plamoModelNotDownloaded.userMessage
        case .inferenceFailed:
            "PLaMo 3 Translate で翻訳できませんでした"
        }
    }
}

enum PlamoRuntimeAvailability {
    /// The llama.cpp runtime ships inside the app (ADR-051); downloading the model is a separate gate.
    static let isAvailable = true
}

/// PLaMo 3 Translate behind `Translating`: builds the PFML3 prompt, cleans the completion.
final class PlamoTranslator: Translating, @unchecked Sendable {
    private let engine: any PlamoInferenceEngine

    init(engine: any PlamoInferenceEngine = LlamaCppPlamoEngine()) {
        self.engine = engine
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard let prompt = PlamoPrompt.prompt(text: text, source: source, target: target) else {
            throw PlamoTranslatorError.invalidInput
        }
        return PlamoPrompt.cleanedOutput(try await engine.generate(prompt: prompt))
    }
}
