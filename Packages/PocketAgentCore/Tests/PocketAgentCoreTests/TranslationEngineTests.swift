import Foundation
import Testing
@testable import PocketAgentCore

struct TranslationEngineChoiceTests {
    @Test func displayNamesAndStorageKey() {
        #expect(TranslationEngineChoice.storageKey == "translation.engine")
        #expect(TranslationEngineChoice.apple.displayName == "Apple Translation（端末内）")
        #expect(TranslationEngineChoice.plamo.displayName == "PLaMo 3 Translate（端末内）")
    }

    @Test func rawValueRoundTrips() {
        #expect(TranslationEngineChoice.allCases == [.apple, .plamo])
        for choice in TranslationEngineChoice.allCases {
            #expect(TranslationEngineChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(TranslationEngineChoice.apple.rawValue == "apple")
        #expect(TranslationEngineChoice.plamo.rawValue == "plamo")
        #expect(TranslationEngineChoice(rawValue: "google") == nil)
    }
}

struct PlamoPromptTests {
    @Test func japaneseToEnglishPrompt() {
        let prompt = PlamoPrompt.prompt(text: "納期は延ばせますか？", source: "ja", target: "en")
        #expect(prompt == "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>納期は延ばせますか？"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>")
    }

    @Test func languageCodesAreLowercased() {
        let upper = PlamoPrompt.prompt(text: "Hello", source: "EN", target: "ZH-Hans")
        let lower = PlamoPrompt.prompt(text: "Hello", source: "en", target: "zh-hans")
        #expect(upper != nil)
        #expect(upper == lower)
        #expect(upper?.contains("<|plamo:val|>en<|plamo:msg|>Hello") == true)
        #expect(upper?.hasSuffix("<|plamo:val|>zh-hans<|plamo:msg|>") == true)
    }

    @Test(arguments: ["", " ", "  \t\n\r "])
    func blankTextIsRejected(text: String) {
        #expect(PlamoPrompt.prompt(text: text, source: "ja", target: "en") == nil)
    }

    @Test func textWithPfmlMarkerIsRejected() {
        #expect(PlamoPrompt.prompt(text: "前<|plamo:tag|>後", source: "ja", target: "en") == nil)
        #expect(PlamoPrompt.prompt(text: "<|plamo:", source: "ja", target: "en") == nil)
    }

    @Test(arguments: ["", "j", "japanese", "j1", "ja-", "ja-jp", "zh-hans-cn", "ja_JP", "日本"])
    func invalidLanguageCodeIsRejected(code: String) {
        #expect(PlamoPrompt.prompt(text: "こんにちは", source: code, target: "en") == nil)
        #expect(PlamoPrompt.prompt(text: "こんにちは", source: "ja", target: code) == nil)
    }

    @Test func surroundingWhitespaceOfTextIsKept() {
        let prompt = PlamoPrompt.prompt(text: "  Hello \n", source: "en", target: "ja")
        #expect(prompt?.contains("<|plamo:msg|>  Hello \n<|plamo:tag|>output") == true)
    }

    @Test func outputIsCutAtFirstStopMarker() {
        #expect(PlamoPrompt.cleanedOutput(" Can the deadline move?\n<|plamo:tag|>junk") == "Can the deadline move?")
        #expect(PlamoPrompt.cleanedOutput("Yes.<|plamo:bos|>more<|plamo:tag|>x") == "Yes.")
        #expect(PlamoPrompt.cleanedOutput("A<|plamo:tag|>B<|plamo:bos|>C") == "A")
        #expect(PlamoPrompt.cleanedOutput("<|plamo:tag|>everything after") == "")
    }

    @Test func outputWithoutMarkerIsOnlyTrimmed() {
        #expect(PlamoPrompt.cleanedOutput("\n  価格表は金曜日までに送ります。 \n") == "価格表は金曜日までに送ります。")
        #expect(PlamoPrompt.cleanedOutput("a  b") == "a  b")
    }
}

struct TranslationEngineResolverTests {
    @Test func appleInstalledResolvesToApple() {
        let resolution = TranslationEngineResolver.resolve(
            choice: .apple, appleInstalled: true, plamoDownloaded: false, plamoRuntimeAvailable: false)
        #expect(resolution == .apple)
    }

    @Test func appleNotInstalledIsUnavailable() {
        // Never falls back to PLaMo, even when PLaMo could run.
        let resolution = TranslationEngineResolver.resolve(
            choice: .apple, appleInstalled: false, plamoDownloaded: true, plamoRuntimeAvailable: true)
        #expect(resolution == .unavailable(.applePairNotInstalled))
    }

    @Test func plamoNotDownloadedIsUnavailable() {
        // Never falls back to Apple, even when the Apple pair is installed.
        let resolution = TranslationEngineResolver.resolve(
            choice: .plamo, appleInstalled: true, plamoDownloaded: false, plamoRuntimeAvailable: true)
        #expect(resolution == .unavailable(.plamoModelNotDownloaded))
    }

    @Test func plamoDownloadedWithoutRuntimeIsUnavailable() {
        let resolution = TranslationEngineResolver.resolve(
            choice: .plamo, appleInstalled: true, plamoDownloaded: true, plamoRuntimeAvailable: false)
        #expect(resolution == .unavailable(.plamoRuntimeUnavailable))
    }

    @Test func plamoDownloadedWithRuntimeResolvesToPlamo() {
        let resolution = TranslationEngineResolver.resolve(
            choice: .plamo, appleInstalled: false, plamoDownloaded: true, plamoRuntimeAvailable: true)
        #expect(resolution == .plamo)
    }

    @Test func unavailableReasonsHaveUserMessages() {
        #expect(TranslationEngineResolver.UnavailableReason.applePairNotInstalled.userMessage == "翻訳データが未導入です")
        #expect(TranslationEngineResolver.UnavailableReason.plamoModelNotDownloaded.userMessage.contains("設定からダウンロード"))
        #expect(TranslationEngineResolver.UnavailableReason.plamoRuntimeUnavailable.userMessage
            == "PLaMo 3 Translate の推論ランタイムは未統合です（ADR-050）")
    }
}
