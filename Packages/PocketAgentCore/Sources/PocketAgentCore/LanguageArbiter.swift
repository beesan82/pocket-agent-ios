import Foundation

/// One final result from one language's recognizer, with when it was spoken and when it arrived
/// (all in seconds on the capture's clock).
public struct LaneCandidate: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The recognizer's language: "ja" or "en".
    public let language: String
    public let text: String
    /// Per-word confidence averaged by characters; nil when the recognizer reported none.
    public let confidence: Double?
    public let start: TimeInterval
    public let end: TimeInterval
    public let arrivedAt: TimeInterval

    public init(
        id: UUID = UUID(), language: String, text: String, confidence: Double?,
        start: TimeInterval, end: TimeInterval, arrivedAt: TimeInterval
    ) {
        self.id = id
        self.language = language
        self.text = text
        self.confidence = confidence
        self.start = start
        self.end = end
        self.arrivedAt = arrivedAt
    }
}

public enum ConfidenceMath {
    /// Average weighted by characters, over the runs that carry a confidence.
    public static func weightedAverage(_ runs: [(characters: Int, confidence: Double?)]) -> Double? {
        var weighted = 0.0
        var total = 0
        for run in runs {
            guard let confidence = run.confidence, run.characters > 0 else { continue }
            weighted += confidence * Double(run.characters)
            total += run.characters
        }
        return total > 0 ? weighted / Double(total) : nil
    }
}

public enum ScriptGuess {
    /// Share of kana and kanji among the letters (punctuation, digits and spaces are ignored).
    public static func japaneseRatio(_ text: String) -> Double {
        var japanese = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            if isJapanese(scalar) {
                japanese += 1
                letters += 1
            } else if CharacterSet.letters.contains(scalar) {
                letters += 1
            }
        }
        return letters > 0 ? Double(japanese) / Double(letters) : 0
    }

    public static func language(of text: String) -> String {
        japaneseRatio(text) >= 0.5 ? "ja" : "en"
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF66...0xFF9F: true
        default: false
        }
    }
}

public struct ArbiterDecision: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Both recognizers heard it; the more confident one won.
        case compared
        /// Only one recognizer reported it, confidently enough.
        case single
        /// Too unsure to show (noise, fillers).
        case noise
        /// Arrived after an overlapping utterance was already decided; never shown twice.
        case late
    }

    public let language: String?
    public let accepted: [LaneCandidate]
    public let rejected: [LaneCandidate]
    public let reason: Reason
    /// When the decision was made (capture clock): the moment the accepted text can be shown.
    /// 0 means unknown (then the candidates' arrival counts).
    public let decidedAt: TimeInterval

    public init(
        language: String?, accepted: [LaneCandidate], rejected: [LaneCandidate], reason: Reason,
        decidedAt: TimeInterval = 0
    ) {
        self.language = language
        self.accepted = accepted
        self.rejected = rejected
        self.reason = reason
        self.decidedAt = decidedAt
    }
}

/// Picks the language of each utterance from two recognizers running on the same audio.
/// Candidates are held `holdSeconds` so the other recognizer's overlapping result can join;
/// a decided utterance is never revised (a late overlapping result is dropped).
public struct LanguageArbiter: Sendable {
    public static let holdSeconds: TimeInterval = 1.5
    public static let acceptConfidence = 0.6
    public static let floorConfidence = 0.3
    /// A lane without confidence counts as this in a comparison (neither sure nor unsure).
    static let neutralConfidence = 0.5
    static let overlapTolerance: TimeInterval = 0.1
    static let decidedMemory: TimeInterval = 30

    private struct Group {
        var candidates: [LaneCandidate]
        var start: TimeInterval
        var end: TimeInterval
        let deadline: TimeInterval
    }

    private struct DecidedSpan {
        let language: String?
        let start: TimeInterval
        let end: TimeInterval
    }

    private var groups: [Group] = []
    private var decided: [DecidedSpan] = []

    public init() {}

    /// Adds a candidate; returns the decisions that became due by its arrival time (late drops included).
    public mutating func submit(_ candidate: LaneCandidate) -> [ArbiterDecision] {
        var decisions = flush(now: candidate.arrivedAt)
        if decided.contains(where: { Self.overlaps($0.start, $0.end, candidate.start, candidate.end) }) {
            decisions.append(ArbiterDecision(
                language: nil, accepted: [], rejected: [candidate], reason: .late, decidedAt: candidate.arrivedAt))
            return decisions
        }
        // A candidate may bridge several held groups (one lane split what the other heard as one): merge them.
        let overlapping = groups.indices.filter {
            Self.overlaps(groups[$0].start, groups[$0].end, candidate.start, candidate.end)
        }
        var merged = Group(
            candidates: [candidate], start: candidate.start, end: candidate.end,
            deadline: candidate.arrivedAt + Self.holdSeconds)
        for index in overlapping.reversed() {
            let group = groups.remove(at: index)
            merged = Group(
                candidates: group.candidates + merged.candidates, start: min(group.start, merged.start),
                end: max(group.end, merged.end), deadline: min(group.deadline, merged.deadline))
        }
        groups.insert(merged, at: min(overlapping.first ?? groups.endIndex, groups.endIndex))
        return decisions
    }

    /// Decides every group whose hold has passed.
    public mutating func flush(now: TimeInterval) -> [ArbiterDecision] {
        decided.removeAll { $0.end < now - Self.decidedMemory }
        var decisions: [ArbiterDecision] = []
        while let index = groups.firstIndex(where: { now + 1e-9 >= $0.deadline }) {
            decisions.append(decide(groups.remove(at: index), at: now))
        }
        return decisions
    }

    /// Decides everything still held (at the end of a capture). Without `now`, each group counts
    /// as decided when its last candidate arrived.
    public mutating func drain(now: TimeInterval? = nil) -> [ArbiterDecision] {
        let pending = groups
        groups = []
        return pending.map { decide($0, at: now ?? ($0.candidates.map(\.arrivedAt).max() ?? 0)) }
    }

    private mutating func decide(_ group: Group, at time: TimeInterval) -> ArbiterDecision {
        let byLanguage = Dictionary(grouping: group.candidates, by: \.language)
        let judged = byLanguage.count >= 2 ? compare(byLanguage) : single(group.candidates)
        decided.append(DecidedSpan(language: judged.language, start: group.start, end: group.end))
        return ArbiterDecision(
            language: judged.language, accepted: judged.accepted, rejected: judged.rejected,
            reason: judged.reason, decidedAt: time)
    }

    private func compare(_ byLanguage: [String: [LaneCandidate]]) -> ArbiterDecision {
        let scores = byLanguage.mapValues { Self.confidence(of: $0) }
        let all = byLanguage.values.flatMap { $0 }
        let known = scores.values.compactMap { $0 }
        if known.count == scores.count, known.allSatisfy({ $0 < Self.floorConfidence }) {
            return ArbiterDecision(language: nil, accepted: [], rejected: Self.ordered(all), reason: .noise)
        }
        let winner = byLanguage.keys.sorted().max { lhs, rhs in
            let left = scores[lhs].flatMap { $0 } ?? Self.neutralConfidence
            let right = scores[rhs].flatMap { $0 } ?? Self.neutralConfidence
            if left != right { return left < right }
            return Self.tieBreak(lhs, rhs, byLanguage)
        } ?? "ja"
        let accepted = Self.ordered(byLanguage[winner] ?? [])
        let rejected = Self.ordered(all.filter { $0.language != winner })
        return ArbiterDecision(language: winner, accepted: accepted, rejected: rejected, reason: .compared)
    }

    /// Equal scores: the Japanese lane wins when its text really is Japanese script.
    private static func tieBreak(_ lhs: String, _ rhs: String, _ byLanguage: [String: [LaneCandidate]]) -> Bool {
        let jaText = (byLanguage["ja"] ?? []).map(\.text).joined()
        let preferred = ScriptGuess.language(of: jaText) == "ja" ? "ja" : "en"
        return rhs == preferred  // "lhs < rhs" when rhs is preferred, so `max` returns it
    }

    private func single(_ candidates: [LaneCandidate]) -> ArbiterDecision {
        let language = candidates.first?.language ?? "ja"
        let ordered = Self.ordered(candidates)
        let accepted: Bool
        if let score = Self.confidence(of: candidates) {
            accepted = score >= Self.floorConfidence
        } else {
            accepted = ScriptGuess.language(of: candidates.map(\.text).joined()) == language
        }
        return accepted
            ? ArbiterDecision(language: language, accepted: ordered, rejected: [], reason: .single)
            : ArbiterDecision(language: nil, accepted: [], rejected: ordered, reason: .noise)
    }

    private static func confidence(of candidates: [LaneCandidate]) -> Double? {
        ConfidenceMath.weightedAverage(candidates.map { ($0.text.count, $0.confidence) })
    }

    private static func ordered(_ candidates: [LaneCandidate]) -> [LaneCandidate] {
        candidates.sorted { ($0.start, $0.arrivedAt) < ($1.start, $1.arrivedAt) }
    }

    private static func overlaps(_ a0: TimeInterval, _ a1: TimeInterval, _ b0: TimeInterval, _ b1: TimeInterval) -> Bool {
        a0 < b1 - overlapTolerance && b0 < a1 - overlapTolerance
    }
}
