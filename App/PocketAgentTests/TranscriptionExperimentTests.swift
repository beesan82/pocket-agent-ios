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
