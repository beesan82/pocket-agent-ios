import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

/// Scripted on-device translation: "<target>:<text>", optional failures, optional hang.
final class FakeTranslator: Translating, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var failuresLeft = 0
    private var hangs = false

    init(failures: Int = 0, hangs: Bool = false) {
        self.failuresLeft = failures
        self.hangs = hangs
    }

    var calls: [String] { lock.withLock { recorded } }

    enum FakeError: Error { case scripted }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let (fail, hang) = lock.withLock { () -> (Bool, Bool) in
            recorded.append(text)
            if failuresLeft > 0 {
                failuresLeft -= 1
                return (true, false)
            }
            return (false, hangs)
        }
        if fail { throw FakeError.scripted }
        if hang { try await Task.sleep(for: .seconds(60)) }
        return "\(target):\(text)"
    }
}

@MainActor
struct BilingualMeetingTests {
    private struct Setup {
        let session: MeetingSession
        let single: FakeTranscriptSource
        let bilingual: FakeTranscriptSource
        let store: InMemoryJournalStore
        let translator: FakeTranslator
        let clock: TestClock
    }

    private func make(
        translator: FakeTranslator = FakeTranslator(), assistant: FakeJournalAssistant? = nil, bilingual: Bool = true
    ) -> Setup {
        let single = FakeTranscriptSource()
        let two = FakeTranscriptSource()
        let store = InMemoryJournalStore()
        let clock = TestClock()
        let session = MeetingSession(
            source: single, bilingualSource: two, translator: translator, store: store, assistant: assistant,
            now: { clock.now })
        session.setBilingual(bilingual)
        return Setup(session: session, single: single, bilingual: two, store: store, translator: translator, clock: clock)
    }

    private func candidate(
        _ language: String, _ text: String, confidence: Double, start: TimeInterval, end: TimeInterval,
        arrivedAt: TimeInterval
    ) -> TranscriptEvent {
        .candidate(LaneCandidate(
            language: language, text: text, confidence: confidence, start: start, end: end, arrivedAt: arrivedAt))
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func bilingualCandidatesBecomeSegmentsWithLanguage() async throws {
        let setup = make()
        await setup.session.start()
        #expect(setup.bilingual.startCount == 1)
        #expect(setup.single.startCount == 0)

        setup.bilingual.yield(candidate("ja", "納期は延ばせますか", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        setup.bilingual.yield(candidate("en", "No key was", confidence: 0.2, start: 1, end: 2, arrivedAt: 2.2))
        await settle()
        #expect(setup.session.segments.isEmpty)  // held for the other recognizer

        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.count == 1)
        #expect(setup.session.segments.first?.language == "ja")
        #expect(setup.session.segments.first?.text == "納期は延ばせますか")
        #expect(setup.session.segments.first?.offset == 1)
    }

    @Test func acceptedSegmentsAreTranslatedInArrivalOrder() async throws {
        let setup = make()
        await setup.session.start()
        setup.bilingual.yield(candidate("ja", "こんにちは", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        setup.bilingual.yield(candidate("en", "Thanks", confidence: 0.9, start: 3, end: 4, arrivedAt: 4.1))
        await settle()
        setup.bilingual.elapsed = 6
        setup.session.tick()
        await settle()
        await setup.session.translationTask?.value

        #expect(setup.session.segments.map(\.translation) == ["en:こんにちは", "ja:Thanks"])
        #expect(setup.translator.calls == ["こんにちは", "Thanks"])
    }

    @Test func translationFailureKeepsOriginalAndRetriesOnForeground() async throws {
        let setup = make(translator: FakeTranslator(failures: 1))
        await setup.session.start()
        setup.bilingual.yield(candidate("en", "Thanks", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()
        await setup.session.translationTask?.value
        #expect(setup.session.segments.first?.text == "Thanks")
        #expect(setup.session.segments.first?.translation == nil)

        setup.session.setForeground(false)
        setup.session.setForeground(true)
        await settle()
        await setup.session.translationTask?.value

        #expect(setup.session.segments.first?.translation == "ja:Thanks")
        #expect(setup.translator.calls.count == 2)
    }

    @Test func notesInputUsesJapaneseSide() async throws {
        let assistant = FakeJournalAssistant(notesChunks: ["## 決まったこと\n- A\n## 宿題\n- B\n## 論点・未決\n- C"])
        let setup = make(assistant: assistant)
        await setup.session.start()
        setup.bilingual.yield(candidate("en", "Thanks", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()
        await setup.session.translationTask?.value

        setup.session.updateNotesNow()
        await setup.session.notesTask?.value

        #expect(assistant.notesCalls.calls.first?.newText == "ja:Thanks")
    }

    @Test func bilingualOffNeverTranslates() async throws {
        let setup = make(bilingual: false)
        await setup.session.start()
        #expect(setup.single.startCount == 1)
        #expect(setup.bilingual.startCount == 0)

        setup.single.yield(.final(TranscriptSegment(offset: 1, text: "こんにちは")))
        setup.single.yield(candidate("en", "Ignored", confidence: 0.9, start: 2, end: 3, arrivedAt: 3.1))
        await settle()
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.map(\.text) == ["こんにちは"])
        #expect(setup.translator.calls.isEmpty)
    }

    @Test func finishDrainsHeldCandidatesAndSavesBothTexts() async throws {
        let setup = make()
        await setup.session.start()
        setup.bilingual.yield(candidate("ja", "こんにちは", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()

        await setup.session.finish()

        #expect(setup.session.state == .saved)
        let saved = try await setup.store.all()
        #expect(saved.first?.body == "[00:01] こんにちは\n    → en:こんにちは")
    }

    @Test func translationWaitIsBounded() async throws {
        let setup = make(translator: FakeTranslator(hangs: true))
        setup.session.translationWait = .milliseconds(200)
        await setup.session.start()
        setup.bilingual.yield(candidate("en", "Thanks", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()

        await setup.session.finish()

        #expect(setup.session.state == .saved)
        let saved = try await setup.store.all()
        #expect(saved.first?.body == "[00:01] (EN) Thanks")
    }

    @Test func resumeStartsAFreshArbiter() async throws {
        let setup = make()
        await setup.session.start()
        setup.bilingual.yield(candidate("ja", "一つ目", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        setup.bilingual.yield(.failed("x"))
        await settle()
        #expect(setup.session.state == .paused("x"))

        setup.clock.now += 10
        setup.bilingual.elapsed = 0
        await setup.session.resume()
        // Same capture-clock times as the first utterance: a stale arbiter would drop it as late.
        setup.bilingual.yield(candidate("en", "Second", confidence: 0.9, start: 1, end: 2, arrivedAt: 2.1))
        await settle()
        setup.bilingual.elapsed = 4
        setup.session.tick()
        await settle()

        #expect(setup.session.segments.map(\.text) == ["一つ目", "Second"])
        #expect(setup.session.segments.last?.offset == 11)
    }

    @Test func languageChoiceIsFixedWhileAMeetingIsOpen() async throws {
        let setup = make()
        await setup.session.start()

        setup.session.setBilingual(false)

        #expect(setup.session.bilingual)
    }
}
