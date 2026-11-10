import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

/// The llama.cpp-backed PLaMo engine (ADR-051). The 573 MB model is never present in CI:
/// these tests cover the availability flip and the error surface (missing / corrupt file).
/// The real-model smoke test runs only where the GGUF has been placed by hand.
struct LlamaCppPlamoEngineTests {
    private func missingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "plamo-missing-\(UUID().uuidString).gguf")
    }

    @Test func missingModelFileThrowsModelNotDownloaded() async {
        let engine = LlamaCppPlamoEngine(modelURL: missingURL())

        await #expect(throws: PlamoTranslatorError.modelNotDownloaded) {
            try await engine.generate(prompt: "テスト")
        }
    }

    @Test func corruptModelFileThrowsInferenceFailed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "plamo-corrupt-\(UUID().uuidString).gguf")
        try Data("this is not a gguf file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = LlamaCppPlamoEngine(modelURL: url)

        await #expect(throws: PlamoTranslatorError.inferenceFailed) {
            try await engine.generate(prompt: "テスト")
        }
    }

    @Test func defaultModelURLMatchesTheStoreLayout() {
        let expected = HubPlamoDownloader.directory(of: PlamoModel.translate08B, at: MLXModelStore.baseDirectory)
            .appending(path: PlamoModel.translate08B.fileName)

        #expect(LlamaCppPlamoEngine.defaultModelURL() == expected)
    }

    /// Real-model smoke test: runs only when the GGUF is on this machine
    /// (PLAMO_GGUF_PATH, or the app container's store location). Skipped in CI.
    @Test func realModelTranslatesWhenTheFileIsPresent() async throws {
        let url = ProcessInfo.processInfo.environment["PLAMO_GGUF_PATH"]
            .map { URL(fileURLWithPath: $0) } ?? LlamaCppPlamoEngine.defaultModelURL()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        let engine = LlamaCppPlamoEngine(modelURL: url)
        let prompt = try #require(PlamoPrompt.prompt(text: "納期は延ばせますか？", source: "ja", target: "en"))

        let output = try await engine.generate(prompt: prompt)

        #expect(!PlamoPrompt.cleanedOutput(output).isEmpty)
    }
}
