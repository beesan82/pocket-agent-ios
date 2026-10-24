import Foundation
import Testing
@testable import PocketAgentCore

private func candidate(
    _ language: String, _ text: String, confidence: Double?, start: TimeInterval, end: TimeInterval,
    arrivedAt: TimeInterval
) -> LaneCandidate {
    LaneCandidate(language: language, text: text, confidence: confidence, start: start, end: end, arrivedAt: arrivedAt)
}

struct LanguageArbiterTests {
    @Test func weightedAverageSkipsNil() throws {
        let average = try #require(ConfidenceMath.weightedAverage([(4, 0.9), (2, nil), (4, 0.5)]))
        #expect(abs(average - 0.7) < 0.0001)
        #expect(ConfidenceMath.weightedAverage([(3, nil)]) == nil)
        #expect(ConfidenceMath.weightedAverage([]) == nil)
    }

    @Test func japaneseRatioAndGuess() {
        #expect(ScriptGuess.language(of: "納期は11月末") == "ja")
        #expect(ScriptGuess.language(of: "That is fine") == "en")
        #expect(ScriptGuess.language(of: "") == "en")
        #expect(ScriptGuess.japaneseRatio("あいう") == 1.0)
    }

    @Test func overlappingPairPicksHigherConfidence() {
        var arbiter = LanguageArbiter()
        let ja = candidate("ja", "納期は延ばせますか", confidence: 0.88, start: 1, end: 3, arrivedAt: 3.2)
        let en = candidate("en", "No key was known", confidence: 0.2, start: 1.1, end: 3.1, arrivedAt: 3.4)

        #expect(arbiter.submit(ja).isEmpty)
        #expect(arbiter.submit(en).isEmpty)
        let decisions = arbiter.flush(now: 4.7)

        #expect(decisions.count == 1)
        #expect(decisions.first?.language == "ja")
        #expect(decisions.first?.accepted == [ja])
        #expect(decisions.first?.rejected == [en])
        #expect(decisions.first?.reason == .compared)
    }

    @Test func oneToManyOverlapIsOneGroup() {
        var arbiter = LanguageArbiter()
        let en = candidate("en", "That should be fine but we need the list", confidence: 0.9, start: 0, end: 4, arrivedAt: 4.1)
        let ja1 = candidate("ja", "ざっと", confidence: 0.3, start: 0, end: 1.5, arrivedAt: 3.0)
        let ja2 = candidate("ja", "リスト", confidence: 0.2, start: 1.6, end: 4, arrivedAt: 4.2)

        _ = arbiter.submit(ja1)
        _ = arbiter.submit(en)
        _ = arbiter.submit(ja2)
        let decisions = arbiter.drain()

        #expect(decisions.count == 1)
        #expect(decisions.first?.language == "en")
        #expect(decisions.first?.accepted == [en])
        #expect(Set(decisions.first?.rejected.map(\.id) ?? []) == Set([ja1.id, ja2.id]))
    }

    @Test func candidateSpanningTwoGroupsMergesThem() {
        var arbiter = LanguageArbiter()
        let ja1 = candidate("ja", "ざっと", confidence: 0.35, start: 0, end: 1.5, arrivedAt: 3.0)
        let ja2 = candidate("ja", "リストが", confidence: 0.4, start: 1.6, end: 4, arrivedAt: 4.1)
        let en = candidate("en", "That should be fine but we need the list", confidence: 0.9, start: 0, end: 4, arrivedAt: 4.2)

        _ = arbiter.submit(ja1)
        _ = arbiter.submit(ja2)
        _ = arbiter.submit(en)
        let decisions = arbiter.drain()

        #expect(decisions.count == 1)
        #expect(decisions.first?.language == "en")
        #expect(decisions.first?.accepted == [en])
        #expect(Set(decisions.first?.rejected.map(\.id) ?? []) == Set([ja1.id, ja2.id]))
    }

    @Test func decisionRecordsWhenItWasDecided() {
        var arbiter = LanguageArbiter()
        _ = arbiter.submit(candidate("ja", "はい了解です", confidence: 0.8, start: 1, end: 2, arrivedAt: 2.5))
        #expect(arbiter.flush(now: 4.2).first?.decidedAt == 4.2)

        _ = arbiter.submit(candidate("ja", "次へ", confidence: 0.8, start: 6, end: 7, arrivedAt: 7.4))
        #expect(arbiter.drain(now: 7.9).first?.decidedAt == 7.9)
    }

    @Test func singleIsHeldThenAccepted() {
        var arbiter = LanguageArbiter()
        let ja = candidate("ja", "わかりました", confidence: 0.8, start: 5, end: 6, arrivedAt: 6.1)

        _ = arbiter.submit(ja)
        #expect(arbiter.flush(now: 7.5).isEmpty)
        let decisions = arbiter.flush(now: 7.6)

        #expect(decisions.count == 1)
        #expect(decisions.first?.accepted == [ja])
        #expect(decisions.first?.reason == .single)
        #expect(decisions.first?.language == "ja")
    }

    @Test func lateOverlapIsDiscarded() {
        var arbiter = LanguageArbiter()
        let ja = candidate("ja", "わかりました", confidence: 0.8, start: 5, end: 6, arrivedAt: 6.1)
        _ = arbiter.submit(ja)
        let first = arbiter.flush(now: 7.6)
        #expect(first.first?.accepted == [ja])

        let lateEn = candidate("en", "Walk a lead a mask", confidence: 0.5, start: 5.2, end: 6.0, arrivedAt: 8.0)
        let decisions = arbiter.submit(lateEn)

        #expect(decisions.count == 1)
        #expect(decisions.first?.reason == .late)
        #expect(decisions.first?.accepted.isEmpty == true)
        #expect(decisions.first?.rejected == [lateEn])
        #expect(arbiter.drain().isEmpty)
    }

    @Test func bothBelowFloorIsNoise() {
        var arbiter = LanguageArbiter()
        let ja = candidate("ja", "えー", confidence: 0.2, start: 1, end: 1.4, arrivedAt: 1.5)
        let en = candidate("en", "uh", confidence: 0.1, start: 1, end: 1.4, arrivedAt: 1.5)
        _ = arbiter.submit(ja)
        _ = arbiter.submit(en)

        let decisions = arbiter.drain()

        #expect(decisions.count == 1)
        #expect(decisions.first?.reason == .noise)
        #expect(decisions.first?.language == nil)
        #expect(decisions.first?.accepted.isEmpty == true)
        #expect(decisions.first?.rejected.count == 2)
    }

    @Test func singleBelowFloorIsNoise() {
        var arbiter = LanguageArbiter()
        _ = arbiter.submit(candidate("en", "hm", confidence: 0.2, start: 1, end: 1.2, arrivedAt: 1.3))
        #expect(arbiter.drain().first?.reason == .noise)
    }

    @Test func nilConfidenceUsesScript() {
        var arbiter = LanguageArbiter()
        let ja = candidate("ja", "価格表を送ります", confidence: nil, start: 1, end: 2, arrivedAt: 2.1)
        let en = candidate("en", "cut a cow so cool", confidence: 0.4, start: 1, end: 2, arrivedAt: 2.1)
        _ = arbiter.submit(ja)
        _ = arbiter.submit(en)

        let decisions = arbiter.drain()

        #expect(decisions.first?.language == "ja")
        #expect(decisions.first?.accepted == [ja])

        var single = LanguageArbiter()
        let lone = candidate("en", "価格表", confidence: nil, start: 1, end: 2, arrivedAt: 2.1)
        _ = single.submit(lone)
        #expect(single.drain().first?.reason == .noise)  // the en lane wrote Japanese script: not English
    }

    @Test func drainDecidesEverything() {
        var arbiter = LanguageArbiter()
        _ = arbiter.submit(candidate("ja", "一つ目", confidence: 0.9, start: 0, end: 1, arrivedAt: 1.1))
        _ = arbiter.submit(candidate("en", "Second one", confidence: 0.9, start: 1.5, end: 2.0, arrivedAt: 2.1))

        let decisions = arbiter.drain()

        #expect(decisions.count == 2)
        #expect(decisions.map(\.language) == ["ja", "en"])
        #expect(arbiter.drain().isEmpty)
    }

    @Test func expiredGroupsAreDecidedOnSubmit() {
        var arbiter = LanguageArbiter()
        _ = arbiter.submit(candidate("ja", "一つ目", confidence: 0.9, start: 0, end: 1, arrivedAt: 1.1))
        let decisions = arbiter.submit(candidate("en", "Later", confidence: 0.9, start: 5, end: 6, arrivedAt: 6.1))

        #expect(decisions.count == 1)
        #expect(decisions.first?.language == "ja")
    }
}
