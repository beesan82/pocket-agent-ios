import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

/// Holds a fake stream's continuation so a test can yield late chunks and see termination.
final class StreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var terminatedFlag = false

    var terminated: Bool { lock.withLock { terminatedFlag } }

    func attach(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.terminatedFlag = true }
        }
        lock.withLock { self.continuation = continuation }
    }

    func yield(_ chunk: String) {
        _ = lock.withLock { continuation }?.yield(chunk)
    }
}

/// Scripted `JournalAssisting` for the app's journal screens.
struct FakeJournalAssistant: JournalAssisting {
    /// Chunks `summarize` yields; with `hangAfterChunks` the stream then never finishes.
    var summaryChunks: [String] = []
    var hangAfterChunks = false
    var askEvidence: [PackedEntry] = []
    var askUsedRecentFallback = false
    var answerChunks: [String] = []
    /// When set, the stream (summary or answer) yields its chunks, stays open and reports here.
    var probe: StreamProbe?

    func summarize(_ text: String) -> AsyncThrowingStream<String, Error> {
        let chunks = summaryChunks
        let hang = hangAfterChunks
        let probe = probe
        return AsyncThrowingStream { continuation in
            probe?.attach(continuation)
            for chunk in chunks { continuation.yield(chunk) }
            if !hang && probe == nil { continuation.finish() }
        }
    }

    func ask(_ question: String, store: any JournalStore) async throws -> AskResult {
        let chunks = answerChunks
        let probe = probe
        return AskResult(
            evidence: askEvidence, usedRecentFallback: askUsedRecentFallback,
            answer: AsyncThrowingStream { continuation in
                probe?.attach(continuation)
                for chunk in chunks { continuation.yield(chunk) }
                if probe == nil { continuation.finish() }
            })
    }
}

@MainActor
struct JournalCaptureSessionTests {
    private static let longText = "  " + String(repeating: "今日は会議で来月の計画を話した。", count: 20) + "\n"

    @Test func shortTextSkipsSummary() async throws {
        let store = InMemoryJournalStore()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 短い\n要約"])
        let session = JournalCaptureSession(source: .text, store: store, assistant: assistant, modelReady: true)
        session.transcript = "短いメモ"

        session.beginIfNeeded()

        #expect(session.phase == .editing)
        #expect(session.summaryTask == nil)
        #expect(session.summaryBody.isEmpty)
    }

    @Test func backgroundBlocksAutoSummary() async throws {
        let store = InMemoryJournalStore()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 来月\n会議で来月の計画を話した。"])
        let session = JournalCaptureSession(source: .voice, store: store, assistant: assistant, modelReady: true)
        session.transcript = Self.longText

        session.beginIfNeeded(isForeground: false)

        #expect(session.phase == .editing)
        #expect(session.summaryTask == nil)
        #expect(session.transcript == Self.longText)
    }

    @Test func foregroundStillAutoSummarizes() async throws {
        let store = InMemoryJournalStore()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 来月\n会議で来月の計画を話した。"])
        let session = JournalCaptureSession(source: .voice, store: store, assistant: assistant, modelReady: true)
        session.transcript = Self.longText

        session.beginIfNeeded(isForeground: true)
        #expect(session.phase == .summarizing)
        await session.summaryTask?.value

        #expect(session.phase == .summarized)
    }

    @Test func longTextWithModelSummarizes() async throws {
        let store = InMemoryJournalStore()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 来月", "の計画\n会議で", "来月の計画を話した。"])
        let session = JournalCaptureSession(source: .voice, store: store, assistant: assistant, modelReady: true)
        session.transcript = Self.longText

        session.beginIfNeeded()
        #expect(session.phase == .summarizing)
        await session.summaryTask?.value

        #expect(session.phase == .summarized)
        #expect(session.summaryTitle == "来月の計画")
        #expect(session.summaryBody == "会議で来月の計画を話した。")
    }

    @Test func stopDuringSummaryKeepsTranscript() async throws {
        let store = InMemoryJournalStore()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 途中"], hangAfterChunks: true)
        let session = JournalCaptureSession(source: .voice, store: store, assistant: assistant, modelReady: true)
        session.transcript = Self.longText

        session.beginIfNeeded()
        #expect(session.phase == .summarizing)
        let task = session.summaryTask
        session.stopSummary()
        await task?.value
        #expect(session.phase != .summarizing)

        await session.save(useTranscriptOnly: true)

        #expect(session.phase == .saved)
        let saved = try await store.all()
        #expect(saved.count == 1)
        #expect(saved.first?.body == Self.longText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(saved.first?.transcript == nil)
        #expect(saved.first?.title == nil)
        #expect(saved.first?.source == .voice)
        #expect(saved.first?.origin == .journal)
    }

    @Test func saveWithSummaryStoresBothTexts() async throws {
        let store = InMemoryJournalStore()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 計画\n来月の計画を話した。"])
        let session = JournalCaptureSession(source: .text, store: store, assistant: assistant, modelReady: true)
        session.transcript = Self.longText
        session.beginIfNeeded()
        await session.summaryTask?.value
        session.summaryTitle = "来月の計画"

        await session.save(useTranscriptOnly: false)

        #expect(session.phase == .saved)
        let saved = try await store.all()
        #expect(saved.count == 1)
        #expect(saved.first?.body == "来月の計画を話した。")
        #expect(saved.first?.transcript == Self.longText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(saved.first?.title == "来月の計画")
        #expect(saved.first?.source == .text)
        #expect(saved.first?.origin == .journal)
    }

    @Test func modelNotReadyStillSaves() async throws {
        let store = InMemoryJournalStore()
        let session = JournalCaptureSession(source: .voice, store: store, assistant: nil, modelReady: false)
        session.transcript = Self.longText

        session.beginIfNeeded()
        #expect(session.phase == .editing)
        await session.save(useTranscriptOnly: false)

        #expect(session.phase == .saved)
        let saved = try await store.all()
        #expect(saved.count == 1)
        #expect(saved.first?.body == Self.longText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(saved.first?.transcript == nil)
    }

    @Test func stopSummaryCancelsTheStream() async throws {
        let probe = StreamProbe()
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 途中\n本文の途中"], probe: probe)
        let session = JournalCaptureSession(
            source: .voice, store: InMemoryJournalStore(), assistant: assistant, modelReady: true)
        session.transcript = Self.longText
        session.beginIfNeeded()
        #expect(try await waitForJournal { session.summaryBody == "本文の途中" })

        let task = session.summaryTask
        session.stopSummary()
        await task?.value
        probe.yield("、さらに続き")

        #expect(probe.terminated)
        #expect(session.phase == .summarized)
        #expect(session.summaryBody == "本文の途中")
    }

    @Test func manualSummaryIgnoresThreshold() async throws {
        let assistant = FakeJournalAssistant(summaryChunks: ["見出し: 散歩\n散歩した。"])
        let session = JournalCaptureSession(
            source: .text, store: InMemoryJournalStore(), assistant: assistant, modelReady: true)
        session.transcript = "朝に散歩した"

        session.beginIfNeeded()
        #expect(session.phase == .editing)
        session.summarize()
        await session.summaryTask?.value

        #expect(session.phase == .summarized)
        #expect(session.summaryTitle == "散歩")
        #expect(session.summaryBody == "散歩した。")
    }
}

/// Polls `condition` on the main actor (the sessions update there).
@MainActor
func waitForJournal(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}
