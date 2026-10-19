import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

/// Scripted `JournalAssisting` for the app's journal screens.
struct FakeJournalAssistant: JournalAssisting {
    /// Chunks `summarize` yields; with `hangAfterChunks` the stream then never finishes.
    var summaryChunks: [String] = []
    var hangAfterChunks = false
    var askEvidence: [PackedEntry] = []
    var askUsedRecentFallback = false
    var answerChunks: [String] = []

    func summarize(_ text: String) -> AsyncThrowingStream<String, Error> {
        let chunks = summaryChunks
        let hang = hangAfterChunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if !hang { continuation.finish() }
        }
    }

    func ask(_ question: String, store: any JournalStore) async throws -> AskResult {
        let chunks = answerChunks
        return AskResult(
            evidence: askEvidence, usedRecentFallback: askUsedRecentFallback,
            answer: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
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
}
