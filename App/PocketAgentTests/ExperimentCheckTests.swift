import Foundation
import Testing
@testable import PocketAgent
import PocketAgentCore

/// The experiment series E scoring (ADR-049): same yardstick rules as the
/// A–C check, but the journal lines carry `passage=E1` style ids so the two
/// series never mix, and the dictionary outcome reports the firing count —
/// the headline number for the frozen passages.
struct ExperimentCheckTests {
    /// Passage E1 with all four terms misrecognized the way passage C's
    /// were (every context in E1 satisfies the guarded rules' followings,
    /// so the dictionary restores the reference exactly).
    private var misrecognizedE1: String {
        ExperimentPassage.e1.text
            .replacingOccurrences(of: "露光装置", with: "路行装置")
            .replacingOccurrences(of: "歩留まり", with: "ぶどまり")
            .replacingOccurrences(of: "線幅", with: "先幅")
            .replacingOccurrences(of: "規格", with: "企画")
    }

    @Test func journalLineCarriesTheExperimentIDAndSynthMarker() throws {
        let passage = ExperimentPassage.e1
        let result = try #require(ExperimentCheck.evaluate(
            passage: passage, transcript: passage.text, source: .synth))
        let ref = TranscriptionScorer.normalize(passage.text).count
        #expect(result.cer == 0)
        #expect(result.logLine == "cer.journal passage=E1 cer=0.000 ref=\(ref) hyp=\(ref) src=synth")
    }

    @Test func journalLinesCarryCountsOnly() throws {
        let result = try #require(ExperimentCheck.evaluate(
            passage: .e2, transcript: "まったく違う文です", source: .synth))
        #expect(!result.logLine.contains("露光"))
        #expect(!result.logLine.contains("検査"))
        #expect(result.logLine.hasPrefix("cer.journal passage=E2 "))
        #expect(result.logLine.hasSuffix(" src=synth"))
    }

    @Test func voiceSourceHasNoSynthMarker() throws {
        let result = try #require(ExperimentCheck.evaluate(
            passage: .e1, transcript: ExperimentPassage.e1.text))
        #expect(!result.logLine.contains("src=synth"))
    }

    @Test func dictionaryRestoresMisrecognizedE1() throws {
        let segments = [TranscriptionSegmentCandidates(text: misrecognizedE1, alternatives: [])]
        let outcome = try #require(ExperimentCheck.evaluateDictionary(passage: .e1, segments: segments))
        #expect(outcome.offTermErrorCount == 4)
        #expect(outcome.onTermErrorCount == 0)
        #expect(outcome.correctionCount == 4)
        #expect(outcome.onTranscript == ExperimentPassage.e1.text)
        #expect(outcome.onResult.cer == 0)
        #expect(outcome.offLogLine == outcome.offResult.logLine)
        #expect(outcome.onLogLine == outcome.onResult.logLine + " dict=on termerrors=0 corrections=4")
    }

    @Test func dictionaryNeverFiresOnTheTrapPassageE3() throws {
        let segments = [TranscriptionSegmentCandidates(text: ExperimentPassage.e3.text, alternatives: [])]
        let outcome = try #require(ExperimentCheck.evaluateDictionary(passage: .e3, segments: segments))
        #expect(outcome.correctionCount == 0)
        #expect(outcome.onTranscript == ExperimentPassage.e3.text)
        #expect(outcome.onResult.cer == 0)
        #expect(outcome.onLogLine.hasSuffix(" dict=on termerrors=0 corrections=0"))
        #expect(outcome.offLogLine.hasPrefix("cer.journal passage=E3 "))
    }

    @Test func dictionaryNeverFiresOnE4AndE5References() throws {
        for passage in [ExperimentPassage.e4, .e5] {
            let segments = [TranscriptionSegmentCandidates(text: passage.text, alternatives: [])]
            let outcome = try #require(ExperimentCheck.evaluateDictionary(passage: passage, segments: segments))
            #expect(outcome.correctionCount == 0, "fired on \(passage.id)")
            #expect(outcome.onTranscript == passage.text)
        }
    }
}
