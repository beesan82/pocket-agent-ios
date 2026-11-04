import Foundation
import Testing
@testable import PocketAgentCore

struct AlternativeSelectorTests {
    @Test func candidateWithTheTermBeatsTheTopResult() {
        let selection = AlternativeSelector.select(
            original: "路行装置の納期を確認した",
            alternatives: ["露光装置の納期を確認した"])
        #expect(selection.adoptedAlternative)
        #expect(selection.text == "露光装置の納期を確認した")
        #expect(selection.originalTermCount == 1)  // 納期
        #expect(selection.selectedTermCount == 2)  // 露光装置・納期
    }

    @Test func fullPassageCCandidateFixesEveryTargetTerm() {
        let observed = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"
        let selection = AlternativeSelector.select(
            original: observed,
            alternatives: [TranscriptionCheckPassage.meetingTechnical.text])
        #expect(selection.adoptedAlternative)
        #expect(selection.text == TranscriptionCheckPassage.meetingTechnical.text)
        #expect(selection.originalTermCount == 2)  // 納期・測定
        #expect(selection.selectedTermCount == 6)  // plus 露光装置・歩留まり・線幅・規格
    }

    @Test func equalTermCountsKeepTheOriginal() {
        let original = "露光装置の納期が決まった"
        let selection = AlternativeSelector.select(
            original: original,
            alternatives: ["露光装置の納期が延びた"])
        #expect(!selection.adoptedAlternative)
        #expect(selection.text == original)
    }

    @Test func noTermGainKeepsTheOriginal() {
        let original = "明日の会議は10時からです"
        let selection = AlternativeSelector.select(
            original: original,
            alternatives: ["明日の会議は10時半からです", "明日の会議は9時からです"])
        #expect(!selection.adoptedAlternative)
        #expect(selection.text == original)
    }

    @Test func emptyAlternativesReturnTheOriginal() {
        let selection = AlternativeSelector.select(original: "路行装置です", alternatives: [])
        #expect(!selection.adoptedAlternative)
        #expect(selection.text == "路行装置です")
        #expect(selection.selectedTermCount == selection.originalTermCount)
    }

    @Test func amongWinnersTheSmallestEditDistanceWins() {
        let selection = AlternativeSelector.select(
            original: "路行装置を確認した",
            alternatives: ["露光装置をはるか遠くで確認した", "露光装置を確認した"])
        #expect(selection.adoptedAlternative)
        #expect(selection.text == "露光装置を確認した")
    }

    @Test func distanceOutranksTermCountAmongWinners() {
        // The spec's rule: filter to candidates with more terms than the
        // original, then rank by edit distance — not by term count.
        let selection = AlternativeSelector.select(
            original: "路行装置とぶどまり",
            alternatives: [
                "露光装置と歩留まりの改善を詳しく報告する",
                "露光装置とぶどまり",
            ])
        #expect(selection.adoptedAlternative)
        #expect(selection.text == "露光装置とぶどまり")
    }

    @Test func tiedWinnersKeepTheEarlierCandidate() {
        // Both alternatives normalize to the same string (likelihood order
        // decides); the first one wins and its raw form is returned.
        let selection = AlternativeSelector.select(
            original: "路行装置です",
            alternatives: ["露光装置、です", "露光装置。です"])
        #expect(selection.adoptedAlternative)
        #expect(selection.text == "露光装置、です")
    }

    @Test func punctuationOnlyDifferenceKeepsTheOriginalVerbatim() {
        let original = "明日の会議は10時です"
        let selection = AlternativeSelector.select(
            original: original,
            alternatives: ["明日の会議は、10時です。"])
        #expect(!selection.adoptedAlternative)
        #expect(selection.text == original)
    }

    @Test func passageBDoesNotFire() {
        let text = TranscriptionCheckPassage.monologueMemo.text
        let alternative = text.replacingOccurrences(of: "洗剤", with: "石鹸")
        let selection = AlternativeSelector.select(original: text, alternatives: [alternative])
        #expect(!selection.adoptedAlternative)
        #expect(selection.text == text)
    }

    @Test func passageADoesNotFire() {
        let text = TranscriptionCheckPassage.readingAloud.text
        let alternative = text.replacingOccurrences(of: "始まります", with: "始まりました")
        let selection = AlternativeSelector.select(original: text, alternatives: [alternative])
        #expect(!selection.adoptedAlternative)
        #expect(selection.text == text)
    }
}
