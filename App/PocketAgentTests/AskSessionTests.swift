import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

@MainActor
struct AskSessionTests {
    @Test func askShowsEvidenceAndFallbackFlag() async throws {
        let entry = JournalEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: .voice, origin: .journal,
            body: "散歩した")
        let evidence = [PackedEntry(entry: entry, text: "散歩した")]
        let assistant = FakeJournalAssistant(
            askEvidence: evidence, askUsedRecentFallback: true, answerChunks: ["直近の日誌から", "、散歩しました。"])
        let session = AskSession(store: InMemoryJournalStore(), assistant: assistant)

        session.ask("  最近なにしてた？ ")
        await session.askTask?.value

        #expect(session.phase == .done)
        #expect(session.evidence == evidence)
        #expect(session.usedRecentFallback)
        #expect(session.answer == "直近の日誌から、散歩しました。")
    }

    @Test func stopMidAnswerMarksStoppedAndIgnoresLateChunks() async throws {
        let probe = StreamProbe()
        let assistant = FakeJournalAssistant(answerChunks: ["途中まで"], probe: probe)
        let session = AskSession(store: InMemoryJournalStore(), assistant: assistant)

        session.ask("昨日なにした？")
        #expect(try await waitForJournal { session.answer == "途中まで" })
        let task = session.askTask
        session.stop()
        await task?.value
        probe.yield("、続き")

        #expect(session.phase == .stopped)
        #expect(session.answer == "途中まで")
        #expect(probe.terminated)
    }

    @Test func journalCalendarStartsWeeksOnMonday() {
        let calendar = JournalModelAccess.journalCalendar
        #expect(calendar.firstWeekday == 2)
        #expect(calendar.timeZone == .current)
    }
}
