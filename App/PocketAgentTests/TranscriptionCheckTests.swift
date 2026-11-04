import Foundation
import Testing
@testable import PocketAgent
import PocketAgentCore

struct TranscriptionCheckTests {
    @Test func perfectReadingScoresZeroAndFormatsLogLine() throws {
        let text = TranscriptionCheckPassage.readingAloud.text
        let result = try #require(TranscriptionCheck.evaluate(passage: .readingAloud, transcript: text))
        #expect(result.passage == .readingAloud)
        #expect(result.cer == 0)
        #expect(result.referenceCharacters == 73)
        #expect(result.hypothesisCharacters == 73)
        #expect(result.logLine == "cer.journal passage=A cer=0.000 ref=73 hyp=73")
    }

    @Test func punctuationOnlyDifferenceScoresZero() throws {
        let transcript = String(TranscriptionCheckPassage.readingAloud.text.filter { $0 != "、" && $0 != "。" })
        let result = try #require(TranscriptionCheck.evaluate(passage: .readingAloud, transcript: transcript))
        #expect(result.cer == 0)
        #expect(result.hypothesisCharacters == 73)
    }

    @Test func droppedFirstCharacterScoresOneEdit() throws {
        let transcript = String(TranscriptionCheckPassage.monologueMemo.text.dropFirst())
        let result = try #require(TranscriptionCheck.evaluate(passage: .monologueMemo, transcript: transcript))
        #expect(abs(result.cer - 1.0 / 76.0) < 1e-9)
        #expect(result.referenceCharacters == 76)
        #expect(result.hypothesisCharacters == 75)
        #expect(result.logLine == "cer.journal passage=B cer=0.013 ref=76 hyp=75")
    }

    @Test func emptyTranscriptScoresOne() throws {
        let result = try #require(TranscriptionCheck.evaluate(passage: .meetingTechnical, transcript: ""))
        #expect(result.cer == 1.0)
        #expect(result.referenceCharacters == 81)
        #expect(result.hypothesisCharacters == 0)
        #expect(result.logLine == "cer.journal passage=C cer=1.000 ref=81 hyp=0")
    }

    @Test func synthesizedRunMarksTheLogLineWithSrcSynth() throws {
        let text = TranscriptionCheckPassage.readingAloud.text
        let result = try #require(TranscriptionCheck.evaluate(passage: .readingAloud, transcript: text, source: .synth))
        #expect(result.source == .synth)
        #expect(result.cer == 0)
        #expect(result.logLine == "cer.journal passage=A cer=0.000 ref=73 hyp=73 src=synth")
    }

    @Test func voiceRunIsTheDefaultAndStaysUnmarked() throws {
        let text = TranscriptionCheckPassage.monologueMemo.text
        let result = try #require(TranscriptionCheck.evaluate(passage: .monologueMemo, transcript: text))
        #expect(result.source == .voice)
        #expect(!result.logLine.contains("src="))
    }

    @Test func logLineNeverContainsTheTranscriptOrPassageBody() throws {
        // The measurement log only receives counts and the CER, never body text.
        let text = TranscriptionCheckPassage.readingAloud.text
        let result = try #require(TranscriptionCheck.evaluate(passage: .readingAloud, transcript: text))
        #expect(!result.logLine.contains("半導体工場"))
        #expect(!result.logLine.contains(text))
    }
}
