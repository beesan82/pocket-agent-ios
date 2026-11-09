import Foundation
import PocketAgentCore

/// The score of one experiment-series passage (ADR-049). Same shape as
/// `TranscriptionCheckResult`, but the journal line carries the experiment
/// id (`passage=E1`) so the frozen E series never mixes with the A–C
/// yardstick series. Counts and CER only — never text (ADR-026).
struct ExperimentCheckResult: Equatable {
    let passage: ExperimentPassage
    let source: TranscriptionCheckSource
    let cer: Double
    let referenceCharacters: Int
    let hypothesisCharacters: Int
    let logLine: String
}

/// Scores transcripts of the experiment passages and runs the term
/// dictionary over recognized segments for the ON/OFF comparison — the
/// same arrangement as `TranscriptionCheck` / `TranscriptionExperiment`
/// for A–C, against the frozen E references (ADR-049).
enum ExperimentCheck {
    /// Returns nil when the passage normalizes to nothing, so no CER can
    /// be computed (same condition as `TranscriptionCheck.evaluate`).
    static func evaluate(
        passage: ExperimentPassage, transcript: String,
        source: TranscriptionCheckSource = .voice
    ) -> ExperimentCheckResult? {
        guard let cer = TranscriptionScorer.cer(reference: passage.text, hypothesis: transcript)
        else { return nil }
        let referenceCharacters = TranscriptionScorer.normalize(passage.text).count
        let hypothesisCharacters = TranscriptionScorer.normalize(transcript).count
        var logLine = "cer.journal passage=\(passage.id) cer=\(String(format: "%.3f", cer))"
            + " ref=\(referenceCharacters) hyp=\(hypothesisCharacters)"
        if source == .synth { logLine += " src=synth" }
        return ExperimentCheckResult(
            passage: passage, source: source, cer: cer,
            referenceCharacters: referenceCharacters,
            hypothesisCharacters: hypothesisCharacters, logLine: logLine)
    }

    /// The dictionary ON/OFF comparison of one experiment passage. OFF is
    /// the engine's top results joined as the standard auto check joins
    /// them; ON applies `TermCorrector` per final segment. The firing
    /// count is the headline number for the frozen series: on E1/E2 it
    /// shows the dictionary working on text it was not built from, and on
    /// the trap passage E3 any firing is over-correction (pass bar: 0).
    /// Log lines carry counts and CER only (ADR-026); the ON line adds the
    /// dictionary markers, in the same format as the A–C series.
    static func evaluateDictionary(
        passage: ExperimentPassage, segments: [TranscriptionSegmentCandidates]
    ) -> ExperimentDictionaryOutcome? {
        let offTranscript = segments.map(\.text).joined()
        var correctionCount = 0
        let onTranscript = segments.map { segment in
            let outcome = TermCorrector.correct(segment.text)
            correctionCount += outcome.totalCount
            return outcome.text
        }.joined()
        guard let offResult = evaluate(passage: passage, transcript: offTranscript, source: .synth),
              let onResult = evaluate(passage: passage, transcript: onTranscript, source: .synth)
        else { return nil }
        let offTermErrorCount = TranscriptionTerms.termErrorCount(
            reference: passage.text, hypothesis: offTranscript)
        let onTermErrorCount = TranscriptionTerms.termErrorCount(
            reference: passage.text, hypothesis: onTranscript)
        return ExperimentDictionaryOutcome(
            offResult: offResult, onResult: onResult,
            offTranscript: offTranscript, onTranscript: onTranscript,
            offTermErrorCount: offTermErrorCount, onTermErrorCount: onTermErrorCount,
            correctionCount: correctionCount,
            offLogLine: offResult.logLine,
            onLogLine: onResult.logLine
                + " dict=on termerrors=\(onTermErrorCount) corrections=\(correctionCount)")
    }
}

/// The ON/OFF comparison of one experiment passage under the term
/// dictionary, mirroring `TranscriptionDictionaryOutcome` for A–C.
struct ExperimentDictionaryOutcome {
    let offResult: ExperimentCheckResult
    let onResult: ExperimentCheckResult
    let offTranscript: String
    let onTranscript: String
    let offTermErrorCount: Int
    let onTermErrorCount: Int
    /// Total dictionary firings across all segments — on the trap passage
    /// E3 this must stay 0; any firing there is over-correction.
    let correctionCount: Int
    let offLogLine: String
    let onLogLine: String
}
