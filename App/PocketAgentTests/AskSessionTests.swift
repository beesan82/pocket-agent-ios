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
}
