import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

@MainActor
struct JournalDraftStoreTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "draft-\(UUID()).json")
    }

    @Test func restoresOriginalAndSummaryWithoutGenerating() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let draft = JournalDraft(source: .voice, transcript: "100万円",
            summaryBody: "10万円", summaryTitle: "予算", summarySource: "10万円", isSummaryPartial: true)
        let drafts = JournalDraftStore(fileURL: url)
        try drafts.save(draft)
        let restored = JournalDraftStore(fileURL: url)
        #expect(restored.draft == draft)
        let session = JournalCaptureSession(source: .voice, store: InMemoryJournalStore(),
            assistant: FakeJournalAssistant(summaryChunks: ["勝手な再要約"]), modelReady: true,
            drafts: restored, restoring: draft)
        #expect(session.transcript == "100万円")
        #expect(session.summaryBody == "10万円")
        #expect(session.isSummaryPartial)
        #expect(session.isSummaryStale)
        #expect(session.summaryTask == nil)
    }

    @Test func editsPersistAndSuccessfulSaveClearsDraft() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let drafts = JournalDraftStore(fileURL: url)
        let store = InMemoryJournalStore()
        let session = JournalCaptureSession(source: .text, store: store, assistant: nil,
            modelReady: false, drafts: drafts)
        session.transcript = "保存前の本文"
        #expect(JournalDraftStore(fileURL: url).draft?.transcript == "保存前の本文")
        let draftID = try #require(drafts.draft?.id)
        await session.save(useTranscriptOnly: true)
        #expect(session.phase == .saved)
        #expect(try await store.entry(id: draftID)?.body == "保存前の本文")
        #expect(JournalDraftStore(fileURL: url).draft == nil)
        session.checkpointDraft()
        #expect(JournalDraftStore(fileURL: url).draft == nil)
    }

    @Test func corruptDraftReportsFailureWithoutOverwritingFile() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: url)
        let drafts = JournalDraftStore(fileURL: url)
        #expect(drafts.draft == nil)
        #expect(drafts.errorMessage != nil)
        #expect(try Data(contentsOf: url) == corrupt)
        try drafts.clear()
        #expect(drafts.errorMessage == nil)
    }

    @Test func failedWritePreservesInMemoryDraftAndReportsFailure() throws {
        let base = location()
        try Data().write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let drafts = JournalDraftStore(fileURL: base.appending(path: "impossible.json"))
        let draft = JournalDraft(source: .text, transcript: "消さないで")
        #expect(throws: (any Error).self) { try drafts.save(draft) }
        #expect(drafts.draft == draft)
        #expect(drafts.errorMessage != nil)
    }

    @Test func clearPreventsDraftFromReturning() throws {
        let url = location()
        let drafts = JournalDraftStore(fileURL: url)
        try drafts.save(JournalDraft(source: .text, transcript: "破棄"))
        try drafts.clear()
        #expect(drafts.draft == nil)
        #expect(JournalDraftStore(fileURL: url).draft == nil)
        try drafts.clear()
    }

    @Test func cleanupFailureAfterSaveCannotCreateDuplicate() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let drafts = JournalDraftStore(fileURL: url,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        let store = InMemoryJournalStore()
        let session = JournalCaptureSession(source: .text, store: store, assistant: nil,
            modelReady: false, drafts: drafts)
        session.transcript = "一度だけ保存"
        await session.save(useTranscriptOnly: true)
        #expect(session.phase == .saved)
        #expect(drafts.errorMessage != nil)
        let draft = try #require(JournalDraftStore(fileURL: url).draft)
        let restored = JournalCaptureSession(source: .text, store: store, assistant: nil,
            modelReady: false, drafts: drafts, restoring: draft)
        await restored.save(useTranscriptOnly: true)
        #expect(try await store.all().count == 1)
    }

    @Test func discardStopsLateSummaryAndNeverRecreatesDraft() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let drafts = JournalDraftStore(fileURL: url)
        let probe = StreamProbe()
        let session = JournalCaptureSession(source: .text, store: InMemoryJournalStore(),
            assistant: FakeJournalAssistant(summaryChunks: ["見出し: 途中\n要約"], probe: probe),
            modelReady: true, drafts: drafts)
        session.transcript = "原文"
        session.summarize()
        #expect(try await waitForJournal { session.summaryBody == "要約" })
        try session.discardDraft()
        probe.yield("遅い結果")
        session.checkpointDraft()
        #expect(JournalDraftStore(fileURL: url).draft == nil)
    }
}
