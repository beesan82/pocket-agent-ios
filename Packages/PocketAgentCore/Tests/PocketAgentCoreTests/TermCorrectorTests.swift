import Foundation
import Testing
@testable import PocketAgentCore

struct TermCorrectorTests {
    /// The misrecognized passage C exactly as the engine returned it on
    /// device (2026-11-04 baseline): all four target terms wrong.
    private let observedC = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"

    @Test func rulesCoverTheFourObservedPairs() {
        let byMisrecognition = Dictionary(
            uniqueKeysWithValues: TermCorrector.rules.map { ($0.misrecognition, $0) })
        #expect(byMisrecognition["路行装置"]?.correction == "露光装置")
        #expect(byMisrecognition["路行装置"]?.requiredFollowings == nil)
        #expect(byMisrecognition["ぶどまり"]?.correction == "歩留まり")
        #expect(byMisrecognition["ぶどまり"]?.requiredFollowings == nil)
        #expect(byMisrecognition["企画"]?.correction == "規格")
        #expect(byMisrecognition["企画"]?.requiredFollowings != nil)
        #expect(byMisrecognition["先幅"]?.correction == "線幅")
        #expect(byMisrecognition["先幅"]?.requiredFollowings != nil)
        // Rule ids are unique (they key the per-pair switch and the counts).
        #expect(Set(TermCorrector.rules.map(\.id)).count == TermCorrector.rules.count)
    }

    @Test func unconditionalPairsFireAnywhere() {
        let exposure = TermCorrector.correct("路行装置の納期です")
        #expect(exposure.text == "露光装置の納期です")
        #expect(exposure.totalCount == 1)
        #expect(exposure.counts["exposure"] == 1)
        let yield = TermCorrector.correct("ぶどまりの改善")
        #expect(yield.text == "歩留まりの改善")
        #expect(yield.totalCount == 1)
        #expect(yield.counts["yield"] == 1)
        let twice = TermCorrector.correct("路行装置と路行装置")
        #expect(twice.text == "露光装置と露光装置")
        #expect(twice.totalCount == 2)
    }

    @Test func observedPassageCIsFullyCorrected() {
        let outcome = TermCorrector.correct(observedC)
        #expect(outcome.totalCount == 4)
        #expect(outcome.counts["exposure"] == 1)
        #expect(outcome.counts["yield"] == 1)
        #expect(outcome.counts["spec"] == 1)
        #expect(outcome.counts["line-width"] == 1)
        let reference = TranscriptionCheckPassage.meetingTechnical.text
        #expect(TranscriptionTerms.termErrorCount(reference: reference, hypothesis: outcome.text) == 0)
        // After correction the passage scores exactly like the reference on
        // the ADR-046 series (the remaining raw differences are the missing
        // 、and the 一部/1部 notation, both normalized away).
        #expect(TranscriptionScorer.normalize(outcome.text) == TranscriptionScorer.normalize(reference))
    }

    @Test func contextPairsFireOnlyWithTheirContext() {
        let spec = TermCorrector.correct("一部で企画を超えていました")
        #expect(spec.text == "一部で規格を超えていました")
        #expect(spec.totalCount == 1)
        #expect(TermCorrector.correct("企画外の値です").text == "規格外の値です")
        #expect(TermCorrector.correct("企画値を記録する").text == "規格値を記録する")
        let lineWidth = TermCorrector.correct("先幅のばらつきが大きい")
        #expect(lineWidth.text == "線幅のばらつきが大きい")
        #expect(lineWidth.totalCount == 1)
        // The misrecognition alone, without the context, is left untouched.
        #expect(TermCorrector.correct("先幅のサンプル").totalCount == 0)
        #expect(TermCorrector.correct("先幅").text == "先幅")
    }

    @Test func contextPairsNeverFireOnLegitimateUses() {
        // 企画 as "project/plan" — the ordinary word — must survive intact.
        for text in ["企画を立てます", "新しい企画が始まった", "企画書を作成した",
                     "企画力を高める", "企画案を出す", "企画会議の準備をする",
                     "企画段階の資料", "その企画は好評だった"] {
            let outcome = TermCorrector.correct(text)
            #expect(outcome.totalCount == 0, "over-correction on \(text)")
            #expect(outcome.text == text)
        }
    }

    @Test func correctorNeverFiresOnPassagesAAndB() {
        // Any firing on A or B is over-correction by definition (spec): the
        // two passages contain no technical terms.
        for passage in [TranscriptionCheckPassage.readingAloud, .monologueMemo] {
            let outcome = TermCorrector.correct(passage.text)
            #expect(outcome.totalCount == 0, "fired on passage \(passage.label)")
            #expect(outcome.text == passage.text)
        }
    }

    @Test func correctorIsSilentOnTheCorrectPassageC() {
        let text = TranscriptionCheckPassage.meetingTechnical.text
        let outcome = TermCorrector.correct(text)
        #expect(outcome.totalCount == 0)
        #expect(outcome.text == text)
    }

    @Test func perPairSwitchDisablesOneRuleOnly() {
        let noExposure = TermCorrector.correct("路行装置の納期です", disabledRuleIDs: ["exposure"])
        #expect(noExposure.text == "路行装置の納期です")
        #expect(noExposure.totalCount == 0)
        let noSpec = TermCorrector.correct(observedC, disabledRuleIDs: ["spec"])
        #expect(noSpec.totalCount == 3)
        #expect(noSpec.text.contains("企画を超えて"))
        #expect(noSpec.counts["spec"] == nil)
    }
}
