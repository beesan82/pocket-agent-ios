import Foundation
import Testing
@testable import PocketAgent
import PocketAgentCore

struct TranscriptionExperimentTests {
    private let observedC = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"

    @Test func withoutAlternativesOnMatchesOff() throws {
        let segments = [TranscriptionSegmentCandidates(text: observedC, alternatives: [])]
        let outcome = try #require(TranscriptionExperiment.evaluate(passage: .meetingTechnical, segments: segments))
        #expect(outcome.offResult.cer > 0.08 && outcome.offResult.cer < 0.09)
        #expect(outcome.onResult.cer == outcome.offResult.cer)
        #expect(outcome.onTranscript == observedC)
        #expect(outcome.offTermErrorCount == 4)
        #expect(outcome.onTermErrorCount == 4)
        #expect(outcome.candidateTargetHits == 0)
        #expect(outcome.offLogLine == outcome.offResult.logLine)
        #expect(outcome.onLogLine == outcome.onResult.logLine + " alt=on termerrors=4")
    }

    @Test func selectorAppliesPerSegmentAndFixesPassageC() throws {
        let segments = [TranscriptionSegmentCandidates(
            text: observedC,
            alternatives: [TranscriptionCheckPassage.meetingTechnical.text])]
        let outcome = try #require(TranscriptionExperiment.evaluate(passage: .meetingTechnical, segments: segments))
        #expect(outcome.onTranscript == TranscriptionCheckPassage.meetingTechnical.text)
        #expect(outcome.onResult.cer == 0)
        #expect(outcome.offTermErrorCount == 4)
        #expect(outcome.onTermErrorCount == 0)
        #expect(outcome.candidateTargetHits == 4)
        #expect(outcome.onLogLine.hasSuffix(" alt=on termerrors=0"))
        #expect(outcome.onLogLine.hasPrefix("cer.journal passage=C "))
    }

    @Test func selectorAppliesAcrossSegments() throws {
        let segments = [
            TranscriptionSegmentCandidates(text: "路行装置の", alternatives: ["露光装置の"]),
            TranscriptionSegmentCandidates(text: "納期です", alternatives: []),
        ]
        let outcome = try #require(TranscriptionExperiment.evaluate(passage: .meetingTechnical, segments: segments))
        #expect(outcome.onTranscript == "露光装置の納期です")
    }

    @Test func passageBIsUnchangedByAlternatives() throws {
        let text = TranscriptionCheckPassage.monologueMemo.text
        let segments = [TranscriptionSegmentCandidates(
            text: text,
            alternatives: [text.replacingOccurrences(of: "洗剤", with: "石鹸")])]
        let outcome = try #require(TranscriptionExperiment.evaluate(passage: .monologueMemo, segments: segments))
        #expect(outcome.onTranscript == text)
        #expect(outcome.onResult.cer == 0)
        #expect(outcome.offTermErrorCount == 0)
        #expect(outcome.candidateTargetHits == 0)
    }

    @Test func dictionaryFixesPassageC() throws {
        let segments = [TranscriptionSegmentCandidates(text: observedC, alternatives: [])]
        let outcome = try #require(TranscriptionExperiment.evaluateDictionary(
            passage: .meetingTechnical, segments: segments))
        #expect(outcome.offTermErrorCount == 4)
        #expect(outcome.onTermErrorCount == 0)
        #expect(outcome.correctionCount == 4)
        #expect(outcome.onResult.cer == 0)
        #expect(outcome.offLogLine == outcome.offResult.logLine)
        #expect(outcome.onLogLine == outcome.onResult.logLine + " dict=on termerrors=0 corrections=4")
    }

    @Test func dictionaryAppliesPerSegment() throws {
        let segments = [
            TranscriptionSegmentCandidates(text: "路行装置の", alternatives: []),
            TranscriptionSegmentCandidates(text: "ぶどまりです", alternatives: []),
        ]
        let outcome = try #require(TranscriptionExperiment.evaluateDictionary(
            passage: .meetingTechnical, segments: segments))
        #expect(outcome.onTranscript == "露光装置の歩留まりです")
        #expect(outcome.correctionCount == 2)
    }

    @Test func dictionaryNeverFiresOnPassagesAAndB() throws {
        for passage in [TranscriptionCheckPassage.readingAloud, .monologueMemo] {
            let segments = [TranscriptionSegmentCandidates(text: passage.text, alternatives: [])]
            let outcome = try #require(TranscriptionExperiment.evaluateDictionary(
                passage: passage, segments: segments))
            #expect(outcome.correctionCount == 0, "fired on passage \(passage.label)")
            #expect(outcome.onTranscript == passage.text)
            #expect(outcome.onResult.cer == outcome.offResult.cer)
            #expect(outcome.onTermErrorCount == 0)
        }
    }

    @Test func dictionaryLeavesLegitimateKikakuAlone() throws {
        let segments = [TranscriptionSegmentCandidates(text: "企画を立てます", alternatives: [])]
        let outcome = try #require(TranscriptionExperiment.evaluateDictionary(
            passage: .monologueMemo, segments: segments))
        #expect(outcome.correctionCount == 0)
        #expect(outcome.onTranscript == "企画を立てます")
    }

    @Test func dictionaryLogLinesCarryCountsOnly() throws {
        let segments = [TranscriptionSegmentCandidates(text: observedC, alternatives: [])]
        let outcome = try #require(TranscriptionExperiment.evaluateDictionary(
            passage: .meetingTechnical, segments: segments))
        for line in [outcome.offLogLine, outcome.onLogLine] {
            #expect(!line.contains("露光"))
            #expect(!line.contains("議題"))
            #expect(line.contains("src=synth"))
        }
    }

    @Test func logLinesCarryCountsOnly() throws {
        let segments = [TranscriptionSegmentCandidates(
            text: observedC,
            alternatives: [TranscriptionCheckPassage.meetingTechnical.text])]
        let outcome = try #require(TranscriptionExperiment.evaluate(passage: .meetingTechnical, segments: segments))
        for line in [outcome.offLogLine, outcome.onLogLine] {
            #expect(!line.contains("露光"))
            #expect(!line.contains("議題"))
            #expect(line.contains("src=synth"))
        }
    }
}
