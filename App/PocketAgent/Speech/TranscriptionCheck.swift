import Foundation
import PocketAgentCore

/// The score of one read-aloud transcription check.
struct TranscriptionCheckResult: Equatable {
    let passage: TranscriptionCheckPassage
    let cer: Double
    let referenceCharacters: Int
    let hypothesisCharacters: Int
    /// Carries only the passage id, the CER and the normalized character counts —
    /// never the transcript or the passage body (ADR-026).
    let logLine: String
}

/// Scores a transcript of a fixed passage read aloud. Only text is scored; no audio is ever stored.
enum TranscriptionCheck {
    /// Returns nil when the passage normalizes to nothing, so no CER can be computed.
    static func evaluate(passage: TranscriptionCheckPassage, transcript: String) -> TranscriptionCheckResult? {
        guard let cer = TranscriptionScorer.cer(reference: passage.text, hypothesis: transcript) else { return nil }
        let referenceCharacters = TranscriptionScorer.normalize(passage.text).count
        let hypothesisCharacters = TranscriptionScorer.normalize(transcript).count
        let id = passage.label.prefix(1)
        // The log line holds counts and the CER only; the transcript stays on screen.
        let logLine = "cer.journal passage=\(id) cer=\(String(format: "%.3f", cer))"
            + " ref=\(referenceCharacters) hyp=\(hypothesisCharacters)"
        return TranscriptionCheckResult(
            passage: passage, cer: cer, referenceCharacters: referenceCharacters,
            hypothesisCharacters: hypothesisCharacters, logLine: logLine)
    }
}
