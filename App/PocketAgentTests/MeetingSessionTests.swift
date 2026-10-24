import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

/// Scripted `TranscriptSource`: the test pushes events through `continuation`.
@MainActor
final class FakeTranscriptSource: TranscriptSource {
    var reason: SpeechUnavailableReason?
    var failStart = false
    var elapsed: TimeInterval = 0
    /// Yielded inside `stop()` before the stream ends (the real capture finalizes its last results then).
    var finalOnStop: TranscriptSegment?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var continuation: AsyncStream<TranscriptEvent>.Continuation?

    enum FakeError: Error { case start }

    func refreshAvailability() async {}
    func requestPermissions() async {}
    func installAssets() async throws {}

    func start() async throws -> AsyncStream<TranscriptEvent> {
        startCount += 1
        if failStart { throw FakeError.start }
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        self.continuation = continuation
        return stream
    }

    func stop() async {
        stopCount += 1
        if let finalOnStop { continuation?.yield(.final(finalOnStop)) }
        continuation?.finish()
        continuation = nil
    }

    func yield(_ event: TranscriptEvent) {
        continuation?.yield(event)
    }
}

@MainActor
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000)
}

@MainActor
struct MeetingSessionTests {
    private static let long = String(repeating: "あ", count: 300)
    private static let notesA = "## 決まったこと\n- A\n## 宿題\n- （なし）\n## 論点・未決\n- （なし）"

    private func make(
        assistant: FakeJournalAssistant? = FakeJournalAssistant(notesChunks: [Self.notesA]), clock: TestClock = TestClock()
    ) -> (MeetingSession, FakeTranscriptSource, InMemoryJournalStore) {
        let source = FakeTranscriptSource()
        let store = InMemoryJournalStore()
        let session = MeetingSession(source: source, store: store, assistant: assistant, now: { clock.now })
        return (session, source, store)
    }

    /// Lets the session's event and notes tasks run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func finalSegmentsAppendAndCountPending() async throws {
        let (session, source, _) = make()
        await session.start()
        #expect(session.state == .recording)

        source.yield(.final(TranscriptSegment(offset: 1, text: "あ")))
        source.yield(.volatile("い"))
        await settle()

        #expect(session.segments.count == 1)
        #expect(session.volatileText == "い")
        #expect(session.pendingCharacters == 1)
        #expect(session.notesPhase == .idle)
    }

    @Test func autoUpdateWaitsForThresholdAndForeground() async throws {
        let assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, _) = make(assistant: assistant)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 1, text: String(repeating: "あ", count: 299))))
        await settle()
        #expect(session.notesPhase == .idle)
        #expect(assistant.notesCalls.calls.isEmpty)

        source.yield(.final(TranscriptSegment(offset: 2, text: "い")))
        await settle()
        await session.notesTask?.value
        #expect(session.notes == Self.notesA)
        #expect(session.pendingCharacters == 0)
        #expect(assistant.notesCalls.calls.count == 1)

        session.setForeground(false)
        source.yield(.final(TranscriptSegment(offset: 3, text: Self.long)))
        await settle()
        #expect(session.notesPhase == .idle)
        #expect(assistant.notesCalls.calls.count == 1)
    }

    @Test func becomingForegroundCatchesUp() async throws {
        let assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, _) = make(assistant: assistant)
        await session.start()
        session.setForeground(false)

        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        #expect(assistant.notesCalls.calls.isEmpty)

        session.setForeground(true)
        await settle()
        await session.notesTask?.value

        #expect(assistant.notesCalls.calls.count == 1)
        #expect(assistant.notesCalls.calls.first?.newText == Self.long)
        #expect(assistant.notesCalls.calls.first?.previous == "")
        #expect(session.notes == Self.notesA)
    }

    @Test func secondUpdateWaitsSixtySeconds() async throws {
        let assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let clock = TestClock()
        let (session, source, _) = make(assistant: assistant, clock: clock)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        await session.notesTask?.value
        #expect(assistant.notesCalls.calls.count == 1)

        source.yield(.final(TranscriptSegment(offset: 2, text: Self.long)))
        await settle()
        #expect(assistant.notesCalls.calls.count == 1)
        #expect(session.pendingCharacters == 300)

        clock.now += 60
        source.yield(.final(TranscriptSegment(offset: 3, text: "い")))
        await settle()
        await session.notesTask?.value
        #expect(assistant.notesCalls.calls.count == 2)
        #expect(assistant.notesCalls.calls.last?.previous == Self.notesA)
        #expect(assistant.notesCalls.calls.last?.newText == Self.long + "\nい")
    }

    @Test func manualUpdateIgnoresThreshold() async throws {
        let assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, _) = make(assistant: assistant)
        await session.start()

        session.updateNotesNow()
        #expect(assistant.notesCalls.calls.isEmpty)

        source.yield(.final(TranscriptSegment(offset: 1, text: "あいうえお")))
        await settle()
        session.updateNotesNow()
        await session.notesTask?.value

        #expect(assistant.notesCalls.calls.count == 1)
        #expect(session.notes == Self.notesA)
    }

    @Test func segmentsArrivingDuringUpdateStayPending() async throws {
        let assistant = FakeJournalAssistant(notesChunks: ["## 決まったこと"], notesHang: true)
        let (session, source, _) = make(assistant: assistant)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        #expect(session.notesPhase == .updating)
        #expect(session.draftNotes == "## 決まったこと")

        source.yield(.final(TranscriptSegment(offset: 2, text: String(repeating: "い", count: 10))))
        await settle()
        #expect(session.pendingCharacters == 10)

        let task = session.notesTask
        session.stopNotesUpdate()
        await task?.value

        #expect(session.notesPhase == .idle)
        #expect(session.notes == "")
        #expect(session.draftNotes == "")
        #expect(session.pendingCharacters == 310)
    }

    @Test func failedUpdateKeepsPreviousNotes() async throws {
        var assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, _) = make(assistant: assistant)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        await session.notesTask?.value
        #expect(session.notes == Self.notesA)

        assistant.notesFail = true
        session.assistant = assistant
        source.yield(.final(TranscriptSegment(offset: 2, text: "い")))
        await settle()
        session.updateNotesNow()
        await session.notesTask?.value

        #expect(session.notesPhase == .failed(MeetingSession.notesFailedText))
        #expect(session.notes == Self.notesA)
        #expect(session.pendingCharacters == 1)
    }

    @Test func finishSavesNotesAndTimestampedTranscript() async throws {
        let clock = TestClock()
        let (session, source, store) = make(clock: clock)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 3, text: "おはよう")))
        source.yield(.final(TranscriptSegment(offset: 70, text: Self.long)))
        await settle()
        await session.notesTask?.value
        #expect(session.notes == Self.notesA)

        await session.finish()

        #expect(session.state == .saved)
        #expect(source.stopCount == 1)
        let saved = try await store.all()
        #expect(saved.count == 1)
        #expect(saved.first?.source == .voice)
        #expect(saved.first?.origin == .journal)
        #expect(saved.first?.body == Self.notesA)
        #expect(saved.first?.transcript == "[00:03] おはよう\n[01:10] \(Self.long)")
        #expect(saved.first?.title == MeetingTitle.make(start: clock.now))
    }

    @Test func finishRunsOneLastUpdateForPendingText() async throws {
        let assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, store) = make(assistant: assistant)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 1, text: "短い発言")))
        await settle()
        #expect(assistant.notesCalls.calls.isEmpty)

        await session.finish()

        #expect(assistant.notesCalls.calls.count == 1)
        #expect(session.state == .saved)
        let saved = try await store.all()
        #expect(saved.first?.body == Self.notesA)
        #expect(saved.first?.transcript == "[00:01] 短い発言")
    }

    @Test func finishWithoutModelSavesTranscriptOnly() async throws {
        let (session, source, store) = make(assistant: nil)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "発言")))
        await settle()

        await session.finish()

        #expect(session.state == .saved)
        let saved = try await store.all()
        #expect(saved.first?.body == "[00:01] 発言")
        #expect(saved.first?.transcript == nil)
        #expect(saved.first?.title?.hasPrefix("会議 ") == true)
    }

    @Test func finishWithNoSegmentsDoesNotSave() async throws {
        let (session, _, store) = make()
        await session.start()

        await session.finish()

        #expect(session.state == .failed(MeetingSession.nothingRecognizedText))
        #expect(try await store.all().isEmpty)
    }

    @Test func sourceFailureBecomesPausedAndKeepsSegments() async throws {
        let (session, source, store) = make(assistant: nil)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "発言")))
        source.yield(.failed("x"))
        source.continuation?.finish()
        await settle()

        #expect(session.state == .paused("x"))
        #expect(session.segments.count == 1)

        await session.resume()
        #expect(source.startCount == 2)
        #expect(session.state == .recording)

        await session.finish()
        #expect(session.state == .saved)
        #expect(try await store.all().count == 1)
    }

    @Test func startFailureShowsFixedText() async throws {
        let (session, source, _) = make()
        source.failStart = true

        await session.start()

        #expect(session.state == .failed(MeetingSession.startFailedText))
    }

    @Test func finishIncludesSegmentsFinalizedByStop() async throws {
        let (session, source, store) = make(assistant: nil)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "最初")))
        await settle()
        source.finalOnStop = TranscriptSegment(offset: 9, text: "最後の一言")

        await session.finish()

        #expect(session.state == .saved)
        #expect(session.segments.count == 2)
        let saved = try await store.all()
        #expect(saved.first?.body == "[00:01] 最初\n[00:09] 最後の一言")
    }

    @Test func longBacklogIsSplitIntoBudgetedBatches() async throws {
        let assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, _) = make(assistant: assistant)
        session.batchCharacterBudget = 400
        await session.start()
        session.setForeground(false)
        for offset in 1...3 {
            source.yield(.final(TranscriptSegment(offset: TimeInterval(offset), text: Self.long)))
        }
        await settle()
        #expect(assistant.notesCalls.calls.isEmpty)

        session.setForeground(true)
        for _ in 0..<3 {
            await settle()
            await session.notesTask?.value
        }

        #expect(assistant.notesCalls.calls.count == 3)
        #expect(assistant.notesCalls.calls.allSatisfy { $0.newText == Self.long })
        #expect(session.pendingCharacters == 0)
        #expect(session.notesPhase == .idle)
    }

    @Test func truncatedOutputKeepsPreviousNotes() async throws {
        var assistant = FakeJournalAssistant(notesChunks: [Self.notesA])
        let (session, source, _) = make(assistant: assistant)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        await session.notesTask?.value
        #expect(session.notes == Self.notesA)

        assistant.notesChunks = ["## 決まったこと\n- B\n## 宿題\n- C"]  // cut off before the third heading
        session.assistant = assistant
        source.yield(.final(TranscriptSegment(offset: 2, text: "い")))
        await settle()
        session.updateNotesNow()
        await session.notesTask?.value

        #expect(session.notesPhase == .failed(MeetingSession.notesFailedText))
        #expect(session.notes == Self.notesA)
        #expect(session.pendingCharacters == 1)
    }

    @Test func interruptionEndedResumesRecording() async throws {
        let (session, source, _) = make(assistant: nil)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "発言")))
        source.yield(.failed(MeetingSession.pausedText))
        await settle()
        #expect(session.state == .paused(MeetingSession.pausedText))

        source.yield(.interruptionEnded)
        source.continuation?.finish()
        await settle()

        #expect(source.startCount == 2)
        #expect(session.state == .recording)
        #expect(session.segments.count == 1)
    }

    @Test func resetClearsAssistant() async throws {
        let (session, source, _) = make()
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "発言")))
        await settle()
        await session.finish()
        #expect(session.modelReady)

        session.reset()

        #expect(session.modelReady == false)
    }

    @Test func finishUsesTheGeneratedTitle() async throws {
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 納期と価格表の件\n", "納期を延ばす。"], notesChunks: [Self.notesA])
        let (session, source, store) = make(assistant: assistant)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "納期を延ばします")))
        await settle()

        await session.finish()

        #expect(session.state == .saved)
        #expect(try await store.all().first?.title == "納期と価格表の件")
    }

    @Test func titleFallsBackToDateWhenTheModelGivesNone() async throws {
        let clock = TestClock()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出しなしの本文だけ"], notesChunks: [Self.notesA])
        let (session, source, store) = make(assistant: assistant, clock: clock)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "発言")))
        await settle()

        await session.finish()

        #expect(try await store.all().first?.title == MeetingTitle.make(start: clock.now))
    }

    @Test func titleTimesOut() async throws {
        let clock = TestClock()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出"], hangAfterChunks: true, notesChunks: [Self.notesA])
        let (session, source, store) = make(assistant: assistant, clock: clock)
        session.titleTimeout = .milliseconds(200)
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: "発言")))
        await settle()

        await session.finish()

        #expect(session.state == .saved)
        #expect(try await store.all().first?.title == MeetingTitle.make(start: clock.now))
    }

    @Test func resetAfterSaveClearsEverything() async throws {
        let (session, source, _) = make()
        await session.start()
        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        await session.notesTask?.value
        await session.finish()
        #expect(session.state == .saved)

        session.reset()

        #expect(session.state == .idle)
        #expect(session.segments.isEmpty)
        #expect(session.notes == "")
        #expect(session.pendingCharacters == 0)
    }
}
