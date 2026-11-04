import Foundation

/// Experiment 1 of the term-accuracy work: re-rank one final recognition
/// result against the engine's own alternative transcriptions, using the
/// term list as the only signal (per-candidate confidence is not exposed by
/// the Speech framework). Pure logic in Core so CI can pin the adoption
/// rules without the speech engine
/// (spec: docs/superpowers/specs/2026-11-04-term-accuracy-design.md).
public enum AlternativeSelector {
    /// The outcome of one selection. `text` is the winning string in its raw
    /// form (the original, untouched, unless an alternative was adopted).
    public struct Selection: Equatable, Sendable {
        public let text: String
        public let adoptedAlternative: Bool
        /// Listed terms found in the scorer-normalized original.
        public let originalTermCount: Int
        /// Listed terms found in the scorer-normalized selected text.
        public let selectedTermCount: Int

        public init(
            text: String, adoptedAlternative: Bool,
            originalTermCount: Int, selectedTermCount: Int
        ) {
            self.text = text
            self.adoptedAlternative = adoptedAlternative
            self.originalTermCount = originalTermCount
            self.selectedTermCount = selectedTermCount
        }
    }

    /// Picks between the engine's top result and its alternatives.
    ///
    /// Adoption rule: only candidates whose scorer-normalized form contains
    /// strictly more listed terms than the original are eligible; among them
    /// the smallest edit distance to the normalized original wins, and ties
    /// keep the earlier candidate (the engine's likelihood order). With no
    /// eligible candidate the original is returned verbatim — the selector
    /// never rewrites a result without a term gain.
    public static func select(original: String, alternatives: [String]) -> Selection {
        let normalizedOriginal = TranscriptionScorer.normalize(original)
        let originalTermCount = TranscriptionTerms.countOccurrences(in: normalizedOriginal)
        var winner: (raw: String, termCount: Int, distance: Int)?
        for alternative in alternatives {
            let normalized = TranscriptionScorer.normalize(alternative)
            let termCount = TranscriptionTerms.countOccurrences(in: normalized)
            guard termCount > originalTermCount else { continue }
            let distance = TranscriptionScorer.editDistance(normalizedOriginal, normalized)
            if let current = winner, distance >= current.distance { continue }
            winner = (alternative, termCount, distance)
        }
        guard let winner else {
            return Selection(
                text: original, adoptedAlternative: false,
                originalTermCount: originalTermCount, selectedTermCount: originalTermCount)
        }
        return Selection(
            text: winner.raw, adoptedAlternative: true,
            originalTermCount: originalTermCount, selectedTermCount: winner.termCount)
    }
}
