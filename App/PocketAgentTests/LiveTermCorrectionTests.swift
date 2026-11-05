import Foundation
import Testing
@testable import PocketAgent
import PocketAgentCore

/// The live path's final-text correction (ADR-047, adoption of Experiment 2):
/// `SpeechCapture.consume` passes every final result of the single-language
/// path through `SpeechCapture.correctFinalText` before joining it into
/// `finalText` and emitting the `.final` event; volatile results never reach
/// it. Real recognition is verified on a real device only — CI pins the
/// application point's behavior here, on top of Core's `TermCorrectorTests`.
struct LiveTermCorrectionTests {
    /// Passage C as the engine actually returned it on device (2026-11-04
    /// baseline): all four target terms wrong.
    private let observedC = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"
    private let correctedC = "本日の議題は露光装置の納期と歩留まりの改善についてです。先週の測定では線幅のばらつきが1部で規格を超えていました。原因の切り分けを来週までに行い、対策を報告してください"

    @Test func liveFinalTextCorrectsPassageCErrors() {
        let outcome = SpeechCapture.correctFinalText(observedC)
        #expect(outcome.text == correctedC)
        #expect(outcome.totalCount == 4)
    }

    @Test func liveFinalTextCorrectsPerFinalResult() {
        // The live path applies the corrector once per final result, so a
        // single segment carrying one error is corrected on its own.
        let outcome = SpeechCapture.correctFinalText("ぶどまりの改善です")
        #expect(outcome.text == "歩留まりの改善です")
        #expect(outcome.totalCount == 1)
    }

    @Test func liveFinalTextLeavesPassagesAAndBUntouched() {
        for passage in [TranscriptionCheckPassage.readingAloud, .monologueMemo] {
            let outcome = SpeechCapture.correctFinalText(passage.text)
            #expect(outcome.text == passage.text, "changed passage \(passage.label)")
            #expect(outcome.totalCount == 0, "fired on passage \(passage.label)")
        }
    }

    @Test func liveFinalTextLeavesLegitimateKikakuAlone() {
        // 企画 as an ordinary word ("project/plan") must survive the live
        // path untouched; only the spec collocations rewrite it.
        let text = "来週の企画を立てて、企画書を共有します"
        let outcome = SpeechCapture.correctFinalText(text)
        #expect(outcome.text == text)
        #expect(outcome.totalCount == 0)
    }
}
