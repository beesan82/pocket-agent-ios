import Foundation
import Testing
@testable import PocketAgentCore

struct BilingualRunStatsTests {
    private func candidate(_ language: String, _ confidence: Double?, end: TimeInterval, arrivedAt: TimeInterval) -> LaneCandidate {
        LaneCandidate(language: language, text: "x", confidence: confidence, start: end - 1, end: end, arrivedAt: arrivedAt)
    }

    @Test func statsCountMatchesAndLines() throws {
        let ja1 = candidate("ja", 0.9, end: 2, arrivedAt: 3)
        let en1 = candidate("en", 0.2, end: 2, arrivedAt: 3)
        let ja2 = candidate("ja", 0.8, end: 5, arrivedAt: 7)
        let en2 = candidate("en", 0.7, end: 9, arrivedAt: 10)
        let ja3 = candidate("ja", 0.3, end: 9, arrivedAt: 10)
        let decisions = [
            ArbiterDecision(language: "ja", accepted: [ja1], rejected: [en1], reason: .compared),
            ArbiterDecision(language: "ja", accepted: [ja2], rejected: [], reason: .single),
            ArbiterDecision(language: "en", accepted: [en2], rejected: [ja3], reason: .compared),
            ArbiterDecision(language: nil, accepted: [], rejected: [candidate("en", 0.1, end: 12, arrivedAt: 13)], reason: .noise),
        ]

        let stats = BilingualRunStats(expected: "ja", decisions: decisions, minAvailableMB: 1200)

        #expect(stats.groups == 3)
        #expect(stats.matches == 2)
        let ja: Double = try #require(stats.jaConfidence)
        let en: Double = try #require(stats.enConfidence)
        let delay: Double = try #require(stats.averageDelay)
        let expectedJa: Double = 2.0 / 3.0
        let expectedEn: Double = 1.0 / 3.0
        let expectedDelay: Double = 4.0 / 3.0
        #expect(abs(ja - expectedJa) < 0.0001)
        #expect(abs(en - expectedEn) < 0.0001)
        #expect(abs(delay - expectedDelay) < 0.0001)
        #expect(stats.lines == [
            "二言語 日本語 判定 2/3 一致",
            "信頼度 ja 0.67 / en 0.33",
            "遅延 平均 1.3 秒 / 最小空き 1200 MB",
        ])
        #expect(stats.lines.allSatisfy { $0.count <= 40 })
    }

    @Test func delayIncludesTheHold() throws {
        let ja = LaneCandidate(language: "ja", text: "x", confidence: 0.9, start: 1, end: 2, arrivedAt: 3)
        let decision = ArbiterDecision(language: "ja", accepted: [ja], rejected: [], reason: .single, decidedAt: 4.5)

        let stats = BilingualRunStats(expected: "ja", decisions: [decision], minAvailableMB: nil)

        let delay: Double = try #require(stats.averageDelay)
        #expect(abs(delay - 2.5) < 0.0001)
    }

    @Test func emptyRunShowsPlaceholders() {
        let stats = BilingualRunStats(expected: "en", decisions: [], minAvailableMB: nil)

        #expect(stats.lines == [
            "二言語 英語 判定 0/0 一致",
            "信頼度 ja 未測定 / en 未測定",
            "遅延 平均 未測定 / 最小空き 未測定",
        ])
    }
}
