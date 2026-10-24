import Foundation

/// One bilingual gate run (the tester spoke `expected` for ~30 s), summarized for a screenshot.
public struct BilingualRunStats: Equatable {
    public static let maxLineLength = 40

    public let expected: String
    /// Utterances shown (decisions with an accepted side).
    public let groups: Int
    /// Of those, how many were judged as the language the tester spoke.
    public let matches: Int
    /// Mean confidence of every Japanese / English recognizer result, accepted or not.
    public let jaConfidence: Double?
    public let enConfidence: Double?
    /// Mean seconds from the end of an accepted utterance to when it could be shown (the hold included).
    public let averageDelay: Double?
    public let minAvailableMB: Int?

    public init(expected: String, decisions: [ArbiterDecision], minAvailableMB: Int?) {
        self.expected = expected
        self.minAvailableMB = minAvailableMB
        let shown = decisions.filter { !$0.accepted.isEmpty }
        groups = shown.count
        matches = shown.filter { $0.language == expected }.count
        let everything = decisions.flatMap { $0.accepted + $0.rejected }
        jaConfidence = Self.mean(everything.filter { $0.language == "ja" }.compactMap(\.confidence))
        enConfidence = Self.mean(everything.filter { $0.language == "en" }.compactMap(\.confidence))
        averageDelay = Self.mean(shown.flatMap { decision in
            decision.accepted.map { max(decision.decidedAt, $0.arrivedAt) - $0.end }
        })
    }

    public var lines: [String] {
        let missing = "未測定"
        let name = expected == "ja" ? "日本語" : "英語"
        func score(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? missing }
        let delay = averageDelay.map { String(format: "%.1f 秒", $0) } ?? missing
        let memory = minAvailableMB.map { "\($0) MB" } ?? missing
        return [
            "二言語 \(name) 判定 \(matches)/\(groups) 一致",
            "信頼度 ja \(score(jaConfidence)) / en \(score(enConfidence))",
            "遅延 平均 \(delay) / 最小空き \(memory)",
        ].map { $0.count <= Self.maxLineLength ? $0 : String($0.prefix(Self.maxLineLength - 1)) + "…" }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
