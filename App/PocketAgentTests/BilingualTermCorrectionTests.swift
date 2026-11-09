import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

/// The bilingual path's term-dictionary application (ADR-048, extending the
/// ADR-047 adoption to bilingual meetings): a two-language capture finalizes
/// its text in `MeetingSession` through `LanguageArbiter`, sharing no
/// finalization point with the single-language path, so the adopted
/// `TermCorrector` is applied there — to accepted Japanese candidates only,
/// after the language decision. CI pins that application point here, on top
/// of Core's `TermCorrectorTests` and the single-language
/// `LiveTermCorrectionTests`; real recognition is verified on a real device.
@MainActor
struct BilingualTermCorrectionTests {
    /// Passage C as the engine actually returned it on device (2026-11-04
    /// baseline, the same observed text as `LiveTermCorrectionTests`): all
    /// four target terms wrong.
    private let observedC = "本日の議題は路行装置の納期とぶどまりの改善についてです。先週の測定では先幅のばらつきが1部で企画を超えていました。原因の切り分けを来週までに行い、対策を報告してください"
    private let correctedC = "本日の議題は露光装置の納期と歩留まりの改善についてです。先週の測定では線幅のばらつきが1部で規格を超えていました。原因の切り分けを来週までに行い、対策を報告してください"

    private struct Setup {
        let session: MeetingSession
        let bilingual: FakeTranscriptSource
        let translator: FakeTranslator
    }

    private func make(languages: [String] = ["ja", "en"]) -> Setup {
        let single = FakeTranscriptSource()
        let two = FakeTranscriptSource()
        let store = InMemoryJournalStore()
        let clock = TestClock()
        let translator = FakeTranslator()
        let session = MeetingSession(
            source: single, bilingualSource: two, translator: translator, store: store,
            assistant: nil, now: { clock.now })
        session.setLanguages(languages)
        return Setup(session: session, bilingual: two, translator: translator)
    }

    private func candidate(
        _ language: String, _ text: String, confidence: Double, start: TimeInterval,
        end: TimeInterval, arrivedAt: TimeInterval
    ) -> TranscriptEvent {
        .candidate(LaneCandidate(
            language: language, text: text, confidence: confidence, start: start, end: end,
            arrivedAt: arrivedAt))
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func acceptedJapaneseCandidateIsTermCorrected() async throws {
        let setup = make()
        await setup.session.start()

        setup.bilingual.yield(candidate("ja", observedC, confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.count == 1)
        #expect(setup.session.segments.first?.text == correctedC)
    }

    @Test func correctedJapaneseTextIsWhatGetsTranslated() async throws {
        let setup = make()
        await setup.session.start()

        setup.bilingual.yield(candidate("ja", "路行装置の納期です", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()
        await setup.session.translationTask?.value

        // The translation source is the accepted segment, so it must already
        // carry the corrected text — never the raw misrecognition.
        #expect(setup.translator.calls == ["露光装置の納期です"])
        #expect(setup.session.segments.first?.translation == "en:露光装置の納期です")
    }

    @Test func acceptedEnglishCandidateIsNotTermCorrected() async throws {
        let setup = make()
        await setup.session.start()

        setup.bilingual.yield(candidate("en", "The exposure tool yield improved", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.first?.language == "en")
        #expect(setup.session.segments.first?.text == "The exposure tool yield improved")
    }

    @Test func legitimateKikakuSurvivesTheBilingualPath() async throws {
        let setup = make()
        await setup.session.start()

        // 企画 as an ordinary word ("project/plan") must not be rewritten on
        // the bilingual path either; only the spec collocations fire.
        let text = "来週の企画を立てて、企画書を共有します"
        setup.bilingual.yield(candidate("ja", text, confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.first?.text == text)
    }

    @Test func nonJapaneseLaneOfAJapanesePairIsNotTermCorrected() async throws {
        // The dictionary rewrites Japanese misrecognitions; in a ja/zh pair
        // the Chinese lane's text is not Japanese recognizer output and must
        // pass through untouched even when it contains the same characters.
        let setup = make(languages: ["ja", "zh"])
        await setup.session.start()

        let text = "路行装置の話をします"
        setup.bilingual.yield(candidate("zh", text, confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.first?.language == "zh")
        #expect(setup.session.segments.first?.text == text)
    }

    @Test func laneVolatileTextIsNeverTermCorrected() async throws {
        let setup = make()
        await setup.session.start()

        // Tentative (volatile) results pass through uncorrected on every
        // path; only finals are corrected.
        setup.bilingual.yield(.laneVolatile(language: "ja", text: "路行装置"))
        await settle()

        #expect(setup.session.volatileText == "路行装置")
        #expect(setup.session.segments.isEmpty)
    }

    @Test func rejectedJapaneseCandidateStaysRejected() async throws {
        let setup = make()
        await setup.session.start()

        // The English lane wins the decision; the corrected-or-not Japanese
        // candidate must not appear anywhere.
        setup.bilingual.yield(candidate("ja", "路行装置の納期です", confidence: 0.2, start: 1, end: 2, arrivedAt: 2.1))
        setup.bilingual.yield(candidate("en", "About the delivery date", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.2))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.count == 1)
        #expect(setup.session.segments.first?.language == "en")
        #expect(setup.session.segments.first?.text == "About the delivery date")
    }
}
