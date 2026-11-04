import Foundation
import Testing
@testable import PocketAgentCore

struct TranscriptionScorerTests {
    // Known pairs verified against tools/cer.py (2026-11-03).

    @Test func identicalTextScoresZero() {
        #expect(TranscriptionScorer.cer(reference: "今日は良い天気です。", hypothesis: "今日は良い天気です") == 0)
    }

    @Test func substitutionAndDeletionAreCounted() {
        let cer = TranscriptionScorer.cer(reference: "今日は良い天気です。", hypothesis: "今日は良い天気だ")
        #expect(cer != nil)
        #expect(abs(cer! - 2.0 / 9.0) < 0.0001)
    }

    @Test func fullWidthDigitsAreNormalizedBeforeScoring() {
        // Since ADR-046, kanji and Arabic numeral notations are normalized
        // to the same form before scoring, so this pair scores zero.
        let cer = TranscriptionScorer.cer(reference: "３千億円と、午前１０時。", hypothesis: "三千億円と午前10時")
        #expect(cer == 0)
    }

    @Test func punctuationAndWhitespaceAreIgnored() {
        #expect(TranscriptionScorer.cer(reference: "あ、い。う", hypothesis: "あいう") == 0)
    }

    @Test func emptyReferenceHasNoScore() {
        #expect(TranscriptionScorer.cer(reference: "。", hypothesis: "あ") == nil)
    }

    @Test func editDistanceCountsInsertions() {
        #expect(TranscriptionScorer.editDistance("あい", "あいう") == 1)
        #expect(TranscriptionScorer.editDistance("", "あ") == 1)
        #expect(TranscriptionScorer.editDistance("あ", "") == 1)
    }
}

struct TranscriptionScorerNumeralTests {
    // Numeral notation normalization (ADR-046). The same cases run against
    // tools/cer.py in tools/test_cer.py; both implementations must agree.

    @Test func kanjiNumeralsConvertToArabicForm() {
        #expect(TranscriptionScorer.normalize("三千") == "3000")
        #expect(TranscriptionScorer.normalize("二千二十八") == "2028")
        #expect(TranscriptionScorer.normalize("千二百") == "1200")
        #expect(TranscriptionScorer.normalize("一万二千") == "12000")
        #expect(TranscriptionScorer.normalize("十") == "10")
        #expect(TranscriptionScorer.normalize("二〇二八") == "2028")
        #expect(TranscriptionScorer.normalize("一億二千三百四十五万六千七百八十九") == "123456789")
    }

    @Test func largeUnitsExpandToPlainValues() {
        // The canonical form carries no unit, so the kanji reference and the
        // Arabic-plus-unit hypothesis land on the same string.
        #expect(TranscriptionScorer.normalize("三千億") == "300000000000")
        #expect(TranscriptionScorer.normalize("3000億") == "300000000000")
        #expect(TranscriptionScorer.normalize("3千") == "3000")
    }

    @Test func notationOnlyDifferencesScoreZero() {
        #expect(TranscriptionScorer.cer(reference: "三千", hypothesis: "3000") == 0)
        #expect(TranscriptionScorer.cer(reference: "午前十時", hypothesis: "午前10時") == 0)
        #expect(TranscriptionScorer.cer(reference: "一部", hypothesis: "1部") == 0)
    }

    @Test func textWithoutNumeralsIsUnchanged() {
        #expect(TranscriptionScorer.normalize("露光装置の納期") == "露光装置の納期")
    }

    @Test func unparseableNumeralsAreLeftUnchanged() {
        // A bare large unit reads as part of a word (万一, 万歳), and mixes
        // of the digit-string style with units are ambiguous: hands off.
        #expect(TranscriptionScorer.normalize("億") == "億")
        #expect(TranscriptionScorer.normalize("万一") == "万一")
        #expect(TranscriptionScorer.normalize("三五百") == "三五百")
        #expect(TranscriptionScorer.normalize("二千〇八") == "二千〇八")
    }

    @Test func firstBaselineRescoresUnderTheNewRules() {
        // The 2026-11-04 on-device hypotheses, re-scored with the numeral
        // normalization. Values verified against tools/cer.py.
        let a = TranscriptionScorer.cer(
            reference: TranscriptionCheckPassage.readingAloud.text,
            hypothesis: "来月から新しい半導体工場の建設が始まります。投資額は約3000億円で2028年の稼働を目指しています。完成すれば国内で1200人の雇用が生まれる見込み")
        #expect(a != nil)
        #expect(abs(a! - 2.0 / 82.0) < 0.0001)

        let b = TranscriptionScorer.cer(
            reference: TranscriptionCheckPassage.monologueMemo.text,
            hypothesis: "明日の午前10時に田中さんと打ち合わせがあります。先方から資料がまだ届いていないので、今日の夕方までに確認の連絡を入れます。帰りに牛乳と卵と洗剤を買って帰ります")
        #expect(b == 0)

        let c = TranscriptionScorer.cer(
            reference: TranscriptionCheckPassage.meetingTechnical.text,
            hypothesis: "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください")
        #expect(c != nil)
        #expect(abs(c! - 7.0 / 81.0) < 0.0001)
    }
}

struct TranscriptionCheckPassageTests {
    @Test func threePassagesExistWithNonTrivialTexts() {
        #expect(TranscriptionCheckPassage.allCases.count == 3)
        for passage in TranscriptionCheckPassage.allCases {
            #expect(passage.text.count >= 30)
            #expect(!passage.label.isEmpty)
        }
    }

    @Test func newsPassageMentionsTheFactoryInvestment() {
        let news = TranscriptionCheckPassage.allCases.first { $0.label.contains("読み上げ") }
        #expect(news != nil)
        #expect(news!.text.contains("半導体工場"))
    }
}
