import Foundation

/// Experiment 2 of the term-accuracy work: a guarded correction dictionary
/// that rewrites known misrecognitions in final transcription text. Pure
/// logic in Core so CI can pin the firing rules without the speech engine
/// (spec: docs/superpowers/specs/2026-11-04-term-accuracy-design.md).
///
/// Rules come in two grades. Unconditional rules rewrite strings that are
/// not ordinary Japanese at all （路行装置， ぶどまり）. Context-conditioned
/// rules rewrite a string that is also an ordinary word （企画 = "project",
/// 先幅） only when the text immediately after the occurrence starts with
/// one of the rule's required followings — collocations in which the word
/// functions as the technical term （規格を超える, 規格外, 規格値 for specs;
/// measurement nouns such as のばらつき for line width). A pair whose
/// condition could not be made this precise would not be registered.
///
/// Correction applies to final results only (callers pass final text;
/// volatile results never reach this type), and the outcome reports counts
/// only — which rules fired how often — so callers can log the counts
/// without ever logging text (ADR-026).
public enum TermCorrector {
    /// One misrecognition → correction rule.
    public struct Rule: Equatable, Sendable {
        /// Stable identifier: keys the per-pair switch and the counts.
        public let id: String
        public let misrecognition: String
        public let correction: String
        /// `nil` for unconditional rules. Otherwise an occurrence is
        /// corrected only when the text right after it starts with one of
        /// these strings.
        public let requiredFollowings: [String]?

        public init(
            id: String, misrecognition: String, correction: String,
            requiredFollowings: [String]? = nil
        ) {
            self.id = id
            self.misrecognition = misrecognition
            self.correction = correction
            self.requiredFollowings = requiredFollowings
        }
    }

    /// The corrected text plus firing counts (the only part callers may log).
    public struct Outcome: Equatable, Sendable {
        public let text: String
        public let totalCount: Int
        /// Firings per rule id; rules that never fired are absent.
        public let counts: [String: Int]

        public init(text: String, totalCount: Int, counts: [String: Int]) {
            self.text = text
            self.totalCount = totalCount
            self.counts = counts
        }
    }

    /// The registered pairs, in application order. Seeded from the errors
    /// observed in the fixed-passage C baseline (2026-11-04).
    public static let rules: [Rule] = [
        Rule(id: "exposure", misrecognition: "路行装置", correction: "露光装置"),
        Rule(id: "yield", misrecognition: "ぶどまり", correction: "歩留まり"),
        // 企画 is an ordinary word ("project/plan"), so this fires only in
        // spec collocations: a limit being exceeded （規格を超える/が超える),
        // out-of-spec （規格外） or a spec value （規格値）. A plan is never
        // followed by these — plans are 立てる・始まる・書くもの.
        Rule(
            id: "spec", misrecognition: "企画", correction: "規格",
            requiredFollowings: ["を超え", "が超え", "外", "値"]),
        // 先幅 has no established meaning of its own; the guard restricts
        // the rewrite to measurement collocations of 線幅 (a measured
        // quantity), which is where the misrecognition was observed.
        Rule(
            id: "line-width", misrecognition: "先幅", correction: "線幅",
            requiredFollowings: ["のばらつき", "の変動", "の均一", "の精度",
                                 "の測定", "の管理", "を測定", "を管理", "がばらつ"]),
    ]

    /// Applies every enabled rule to `text`, in registration order.
    /// `disabledRuleIDs` is the per-pair switch: a rule listed there never
    /// fires (the spec's escape hatch when a context pair over-corrects).
    public static func correct(_ text: String, disabledRuleIDs: Set<String> = []) -> Outcome {
        var result = text
        var counts: [String: Int] = [:]
        var total = 0
        for rule in rules where !disabledRuleIDs.contains(rule.id) {
            let (replaced, fired) = apply(rule, to: result)
            result = replaced
            if fired > 0 {
                counts[rule.id] = fired
                total += fired
            }
        }
        return Outcome(text: result, totalCount: total, counts: counts)
    }

    /// One left-to-right pass of a single rule over `text`. Occurrences that
    /// fail the context condition are copied through verbatim.
    private static func apply(_ rule: Rule, to text: String) -> (String, Int) {
        guard !rule.misrecognition.isEmpty else { return (text, 0) }
        var output = ""
        var fired = 0
        var cursor = text.startIndex
        while let found = text.range(of: rule.misrecognition, range: cursor..<text.endIndex) {
            output += text[cursor..<found.lowerBound]
            if fires(rule, at: found, in: text) {
                output += rule.correction
                fired += 1
            } else {
                output += rule.misrecognition
            }
            cursor = found.upperBound
        }
        output += text[cursor...]
        return (output, fired)
    }

    private static func fires(_ rule: Rule, at range: Range<String.Index>, in text: String) -> Bool {
        guard let followings = rule.requiredFollowings else { return true }
        let after = text[range.upperBound...]
        return followings.contains { after.hasPrefix($0) }
    }
}
