import Foundation
import PocketAgentCore

/// One final recognition result with the engine's alternative readings of
/// the same audio span, in likelihood order. Alternatives are empty unless
/// the transcriber ran with the composed options (`ProgressiveTranscriber`).
struct TranscriptionSegmentCandidates: Equatable, Sendable {
    let text: String
    let alternatives: [String]
}

/// The ON/OFF comparison of one passage under Experiment 1 (alternative
/// re-ranking). OFF is the engine's top results joined as the standard auto
/// check joins them; ON applies `AlternativeSelector` per segment first.
/// Both sides are scored with the standard synth series, and the log lines
/// carry counts and CER only — never text (ADR-026). The ON line adds the
/// experiment markers (`alt=on termerrors=…`) to its standard line.
struct TranscriptionExperimentOutcome {
    let offResult: TranscriptionCheckResult
    let onResult: TranscriptionCheckResult
    let offTranscript: String
    let onTranscript: String
    let offTermErrorCount: Int
    let onTermErrorCount: Int
    /// Target terms that appeared in at least one alternative, counted per
    /// segment — how often the engine "had the right answer" among its
    /// candidates at all.
    let candidateTargetHits: Int
    let offLogLine: String
    let onLogLine: String
}

enum TranscriptionExperiment {
    /// Returns nil when the passage cannot be scored (same condition as
    /// `TranscriptionCheck.evaluate`).
    static func evaluate(
        passage: TranscriptionCheckPassage, segments: [TranscriptionSegmentCandidates]
    ) -> TranscriptionExperimentOutcome? {
        let offTranscript = segments.map(\.text).joined()
        let onTranscript = segments.map {
            AlternativeSelector.select(original: $0.text, alternatives: $0.alternatives).text
        }.joined()
        guard let offResult = TranscriptionCheck.evaluate(
                passage: passage, transcript: offTranscript, source: .synth),
              let onResult = TranscriptionCheck.evaluate(
                passage: passage, transcript: onTranscript, source: .synth)
        else { return nil }
        let offTermErrorCount = TranscriptionTerms.termErrorCount(
            reference: passage.text, hypothesis: offTranscript)
        let onTermErrorCount = TranscriptionTerms.termErrorCount(
            reference: passage.text, hypothesis: onTranscript)
        var candidateTargetHits = 0
        for segment in segments {
            let normalizedAlternatives = segment.alternatives.map(TranscriptionScorer.normalize)
            for target in TranscriptionTerms.targets {
                let appears = normalizedAlternatives.contains {
                    TranscriptionTerms.countOccurrences(of: target, in: $0) > 0
                }
                if appears { candidateTargetHits += 1 }
            }
        }
        return TranscriptionExperimentOutcome(
            offResult: offResult, onResult: onResult,
            offTranscript: offTranscript, onTranscript: onTranscript,
            offTermErrorCount: offTermErrorCount, onTermErrorCount: onTermErrorCount,
            candidateTargetHits: candidateTargetHits,
            offLogLine: offResult.logLine,
            onLogLine: onResult.logLine + " alt=on termerrors=\(onTermErrorCount)")
    }
}
