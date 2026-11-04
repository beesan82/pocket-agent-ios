import Foundation
import Testing
@testable import PocketAgentCore

struct TranscriptionTermsTests {
    @Test func listContainsTheFourTargetsAndTheSurroundingTerms() {
        for term in ["露光装置", "歩留まり", "線幅", "規格"] {
            #expect(TranscriptionTerms.targets.contains(term))
            #expect(TranscriptionTerms.all.contains(term))
        }
        for term in ["半導体", "ウェハ", "洗浄", "成膜", "エッチング", "イオン注入",
                     "ダイシング", "ボンディング", "検査", "納期", "測定"] {
            #expect(TranscriptionTerms.all.contains(term), "missing surrounding term \(term)")
        }
    }

    @Test func countOccurrencesCountsNonOverlappingMatches() {
        #expect(TranscriptionTerms.countOccurrences(of: "歩留まり", in: "歩留まりの改善と歩留まり") == 2)
        #expect(TranscriptionTerms.countOccurrences(of: "規格", in: "企画を超えていました") == 0)
        #expect(TranscriptionTerms.countOccurrences(of: "露光装置", in: "") == 0)
    }

    @Test func countOccurrencesInTextSumsTheListedTerms() {
        // The normalized fixed passage C holds six listed terms, one each:
        // 露光装置・納期・歩留まり・測定・線幅・規格.
        let reference = TranscriptionScorer.normalize(TranscriptionCheckPassage.meetingTechnical.text)
        #expect(TranscriptionTerms.countOccurrences(in: reference) == 6)
        // The observed misrecognition keeps only 納期 and 測定 of the list.
        let observed = TranscriptionScorer.normalize(
            "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください")
        #expect(TranscriptionTerms.countOccurrences(in: observed) == 2)
    }

    @Test func termErrorCountIsZeroForAPerfectReading() {
        let text = TranscriptionCheckPassage.meetingTechnical.text
        #expect(TranscriptionTerms.termErrorCount(reference: text, hypothesis: text) == 0)
        // Punctuation is scoring noise, not a term error.
        let unpunctuated = String(text.filter { $0 != "、" && $0 != "。" })
        #expect(TranscriptionTerms.termErrorCount(reference: text, hypothesis: unpunctuated) == 0)
    }

    @Test func termErrorCountCountsEveryMissedTarget() {
        let observed = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"
        #expect(TranscriptionTerms.termErrorCount(
            reference: TranscriptionCheckPassage.meetingTechnical.text, hypothesis: observed) == 4)
        let halfFixed = "本日の議題は露光装置の納期と歩留まりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"
        #expect(TranscriptionTerms.termErrorCount(
            reference: TranscriptionCheckPassage.meetingTechnical.text, hypothesis: halfFixed) == 2)
    }
}
