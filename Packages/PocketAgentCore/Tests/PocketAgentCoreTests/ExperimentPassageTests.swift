import Foundation
import Testing
@testable import PocketAgentCore

/// The experiment series E (ADR-049): unseen passages and a trap passage,
/// frozen before any further dictionary work so later dictionary changes
/// are scored against text they were not built from. Passage C stays the
/// yardstick; the E series never replaces it.
struct ExperimentPassageTests {
    @Test func allFivePassagesExistWithStableIDs() {
        #expect(ExperimentPassage.allCases.map(\.id) == ["E1", "E2", "E3", "E4", "E5"])
        for passage in ExperimentPassage.allCases {
            #expect(!passage.text.isEmpty)
            #expect(!passage.label.isEmpty)
            #expect(passage.label.hasPrefix(passage.id))
        }
    }

    @Test func e1AndE2UseAllFourTargetTermsOnceEach() {
        for passage in [ExperimentPassage.e1, .e2] {
            for term in TranscriptionTerms.targets {
                #expect(
                    TranscriptionTerms.countOccurrences(of: term, in: passage.text) == 1,
                    "\(passage.id) should use \(term) exactly once")
            }
            // Unseen contexts: neither text is passage C, and the two
            // passages differ from each other.
            #expect(passage.text != TranscriptionCheckPassage.meetingTechnical.text)
        }
        #expect(ExperimentPassage.e1.text != ExperimentPassage.e2.text)
        // Same order of length as passage C (88 characters), so one wrong
        // character moves the CER by roughly the same amount.
        for passage in [ExperimentPassage.e1, .e2] {
            #expect(passage.text.count >= 80 && passage.text.count <= 110,
                    "\(passage.id) is \(passage.text.count) characters")
        }
    }

    @Test func e1AndE2ExerciseNumeralNotation() {
        // Kanji numerals, so the ADR-046 numeral normalization is part of
        // what these passages measure (the engine answers in Arabic digits).
        #expect(ExperimentPassage.e1.text.contains("三台"))
        #expect(ExperimentPassage.e1.text.contains("八十八"))
        #expect(ExperimentPassage.e1.text.contains("九十二"))
        #expect(ExperimentPassage.e2.text.contains("十二枚"))
        #expect(ExperimentPassage.e2.text.contains("三回目"))
        // After normalization the values survive as plain Arabic numbers.
        #expect(TranscriptionScorer.normalize(ExperimentPassage.e1.text).contains("88"))
        #expect(TranscriptionScorer.normalize(ExperimentPassage.e1.text).contains("92"))
        #expect(TranscriptionScorer.normalize(ExperimentPassage.e2.text).contains("12"))
    }

    @Test func unseenPassagesContainNoMisrecognitionStrings() {
        // If a reference already contained a misrecognition string, the
        // scorer could not tell the engine's error from the text itself.
        for passage in [ExperimentPassage.e1, .e2, .e4, .e5] {
            for rule in TermCorrector.rules {
                #expect(!passage.text.contains(rule.misrecognition),
                        "\(passage.id) contains \(rule.misrecognition)")
            }
        }
    }

    @Test func trapPassageE3UsesKikakuLegitimatelyAndNeverFires() {
        let text = ExperimentPassage.e3.text
        #expect(ExperimentPassage.e3.isTrapPassage)
        // The ordinary word 企画 ("plan") in collocations that pass next to
        // the spec rule's followings （を超え, 外， 値） without matching
        // them: を出す / 書 / 会議 / の.
        #expect(text.contains("企画を出す"))
        #expect(text.contains("企画書"))
        #expect(text.contains("企画会議"))
        #expect(text.contains("企画の価値"))
        let outcome = TermCorrector.correct(text)
        #expect(outcome.totalCount == 0)
        #expect(outcome.text == text)
    }

    @Test func onlyE3IsTheTrapPassage() {
        for passage in ExperimentPassage.allCases {
            #expect(passage.isTrapPassage == (passage == .e3))
        }
    }

    @Test func e4IsALongEverydayPassageWithoutListedTerms() {
        let text = ExperimentPassage.e4.text
        #expect(text.count >= 280 && text.count <= 320,
                "E4 is \(text.count) characters, expected about 300")
        for term in TranscriptionTerms.all {
            #expect(!text.contains(term), "E4 contains the listed term \(term)")
        }
        // Nothing for the dictionary to fire on either.
        let outcome = TermCorrector.correct(text)
        #expect(outcome.totalCount == 0)
        #expect(outcome.text == text)
    }

    @Test func e5IsRichInNamesPlacesAndKatakana() {
        let text = ExperimentPassage.e5.text
        for name in ["サトウ", "マリア", "京都", "大阪", "バンクーバー", "トロント"] {
            #expect(text.contains(name), "E5 is missing \(name)")
        }
        let katakana = text.filter { ("ァ"..."ヶ").contains($0) }
        #expect(katakana.count >= 30, "E5 has only \(katakana.count) katakana characters")
        let outcome = TermCorrector.correct(text)
        #expect(outcome.totalCount == 0)
        #expect(outcome.text == text)
    }
}
