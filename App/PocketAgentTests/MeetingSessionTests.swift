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
    private static let notesA = "## 決まったこと\n- A"

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
        var assistant = FakeJournalAssistant(notesChunks: ["X"])
        let (session, source, _) = make(assistant: assistant)
        await session.start()

        source.yield(.final(TranscriptSegment(offset: 1, text: Self.long)))
        await settle()
        await session.notesTask?.value
        #expect(session.notes == "X")

        assistant.notesFail = true
        session.assistant = assistant
        source.yield(.final(TranscriptSegment(offset: 2, text: "い")))
        await settle()
        session.updateNotesNow()
        await session.notesTask?.value

        #expect(session.notesPhase == .failed(MeetingSession.notesFailedText))
        #expect(session.notes == "X")
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
