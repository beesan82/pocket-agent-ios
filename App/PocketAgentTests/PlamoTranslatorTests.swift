import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

/// Returns a fixed completion and records the prompts it was given.
private final class FakePlamoEngine: PlamoInferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let output: String
    private var _prompts: [String] = []

    init(output: String) {
        self.output = output
    }

    var prompts: [String] { lock.withLock { _prompts } }

    func generate(prompt: String) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        return output
    }
}

struct PlamoTranslatorTests {
    @Test func passesThePfml3PromptToTheEngine() async throws {
        let engine = FakePlamoEngine(output: "Can the deadline be extended?")
        let translator = PlamoTranslator(engine: engine)

        let output = try await translator.translate("納期は延ばせますか？", from: "ja", to: "en")

        let expected = try #require(PlamoPrompt.prompt(text: "納期は延ばせますか？", source: "ja", target: "en"))
        #expect(output == "Can the deadline be extended?")
        #expect(engine.prompts == [expected])
    }

    @Test func cutsTheOutputAtTheStopMarker() async throws {
        let engine = FakePlamoEngine(output: " 価格表は金曜日までに送ります。\n<|plamo:tag|>dataset<|plamo:msg|>")
        let translator = PlamoTranslator(engine: engine)

        let output = try await translator.translate("I will send the price list by Friday.", from: "en", to: "ja")

        #expect(output == "価格表は金曜日までに送ります。")
    }

    @Test(arguments: [("  ", "ja", "en"), ("a<|plamo:tag|>b", "en", "ja"), ("こんにちは", "japanese", "en")])
    func invalidInputNeverReachesTheEngine(text: String, source: String, target: String) async {
        let engine = FakePlamoEngine(output: "unused")
        let translator = PlamoTranslator(engine: engine)

        await #expect(throws: PlamoTranslatorError.invalidInput) {
            try await translator.translate(text, from: source, to: target)
        }
        #expect(engine.prompts.isEmpty)
    }

    @Test func defaultEngineReportsMissingModel() async {
        // No model is ever downloaded in the test environment (ADR-051).
        let translator = PlamoTranslator()

        await #expect(throws: PlamoTranslatorError.modelNotDownloaded) {
            try await translator.translate("こんにちは", from: "ja", to: "en")
        }
        #expect(PlamoRuntimeAvailability.isAvailable == true)
    }

    @Test func errorMessages() {
        #expect(PlamoTranslatorError.invalidInput.userMessage == "翻訳できない文です")
        #expect(PlamoTranslatorError.modelNotDownloaded.userMessage
            == TranslationEngineResolver.UnavailableReason.plamoModelNotDownloaded.userMessage)
        #expect(PlamoTranslatorError.inferenceFailed.userMessage == "PLaMo 3 Translate で翻訳できませんでした")
    }
}
