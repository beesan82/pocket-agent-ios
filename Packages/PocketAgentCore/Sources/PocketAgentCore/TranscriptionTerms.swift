import Foundation

/// The technical terms the transcription accuracy work tracks, kept in Core
/// as pure data plus counting helpers so CI can test them without the speech
/// engine (spec: docs/superpowers/specs/2026-11-04-term-accuracy-design.md).
///
/// `targets` are the four terms fixed passage C is scored on; `all` adds the
/// surrounding semiconductor vocabulary used when ranking alternative
/// transcriptions (a candidate that surfaces any listed term is preferred).
public enum TranscriptionTerms {
    /// The four target terms of fixed passage C, all misrecognized in the
    /// first synthesized-speech baseline (CER 8.64%, term errors 4).
    public static let targets: [String] = ["露光装置", "歩留まり", "線幅", "規格"]

    /// Semiconductor-domain terms around the targets.
    public static let surrounding: [String] = [
        "半導体", "ウェハ", "洗浄", "成膜", "エッチング", "イオン注入",
        "ダイシング", "ボンディング", "検査", "納期", "測定",
    ]

    /// Every listed term: the targets first, then the surrounding terms.
    public static let all: [String] = targets + surrounding

    /// Non-overlapping occurrences of one term in `text`, counted as written.
    /// Callers pass scorer-normalized text when they want scoring semantics.
    public static func countOccurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: term, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    /// Total occurrences of all listed terms in `text`, counted as written.
    public static func countOccurrences(in text: String) -> Int {
        all.reduce(0) { $0 + countOccurrences(of: $1, in: text) }
    }

    /// How many of the reference's target-term occurrences the hypothesis
    /// failed to reproduce. Both sides are scorer-normalized first, so
    /// punctuation and numeral notation never count as term errors.
    public static func termErrorCount(reference: String, hypothesis: String) -> Int {
        let normalizedReference = TranscriptionScorer.normalize(reference)
        let normalizedHypothesis = TranscriptionScorer.normalize(hypothesis)
        return targets.reduce(0) { sum, term in
            let expected = countOccurrences(of: term, in: normalizedReference)
            let recognized = countOccurrences(of: term, in: normalizedHypothesis)
            return sum + max(0, expected - recognized)
        }
    }
}
