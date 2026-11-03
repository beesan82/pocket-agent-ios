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
        // The digit/kanji notation difference itself counts as one error.
        let cer = TranscriptionScorer.cer(reference: "３千億円と、午前１０時。", hypothesis: "三千億円と午前10時")
        #expect(cer != nil)
        #expect(abs(cer! - 0.1) < 0.0001)
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
