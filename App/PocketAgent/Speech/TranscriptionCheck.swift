import Foundation
import PocketAgentCore

/// Where the scored speech came from: a person reading aloud, or the bundled synthesized voice.
enum TranscriptionCheckSource: String, Sendable {
    case voice
    case synth
}

/// The score of one transcription check.
struct TranscriptionCheckResult: Equatable {
    let passage: TranscriptionCheckPassage
    let source: TranscriptionCheckSource
    let cer: Double
    let referenceCharacters: Int
    let hypothesisCharacters: Int
    /// Carries only the passage id, the CER and the normalized character counts —
    /// never the transcript or the passage body (ADR-026). Synthesized runs add a
    /// trailing `src=synth` so the two series stay separate (ADR-044).
    let logLine: String
}

/// Scores a transcript of a fixed passage. Only text is scored; no audio is ever stored.
enum TranscriptionCheck {
    /// Returns nil when the passage normalizes to nothing, so no CER can be computed.
    static func evaluate(
        passage: TranscriptionCheckPassage, transcript: String, source: TranscriptionCheckSource = .voice
    ) -> TranscriptionCheckResult? {
        guard let cer = TranscriptionScorer.cer(reference: passage.text, hypothesis: transcript) else { return nil }
        let referenceCharacters = TranscriptionScorer.normalize(passage.text).count
        let hypothesisCharacters = TranscriptionScorer.normalize(transcript).count
        let id = passage.label.prefix(1)
        // The log line holds counts and the CER only; the transcript stays on screen.
        var logLine = "cer.journal passage=\(id) cer=\(String(format: "%.3f", cer))"
            + " ref=\(referenceCharacters) hyp=\(hypothesisCharacters)"
        if source == .synth { logLine += " src=synth" }
        return TranscriptionCheckResult(
            passage: passage, source: source, cer: cer, referenceCharacters: referenceCharacters,
            hypothesisCharacters: hypothesisCharacters, logLine: logLine)
    }
}
