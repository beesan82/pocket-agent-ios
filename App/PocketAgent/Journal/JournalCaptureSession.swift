import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// One capture: edit the transcript, optionally summarize on device, then save.
/// Saving the original text never depends on the model.
@MainActor
@Observable
final class JournalCaptureSession {
    enum Phase: Equatable {
        case editing, summarizing, summarized, saving, saved, failed(String)
    }

    static let summaryFailedText = "要約できませんでした。原文のまま保存できます。"
    static let saveFailedText = "保存できませんでした。もう一度お試しください。"
    static let emptyText = "本文が空です。"
    static let staleSummaryText = "本文が変更されています。要約し直すか、原文のまま保存してください。"

    var transcript = "" { didSet { checkpointDraft() } }
    var summaryBody = "" { didSet { if phase != .summarizing { checkpointDraft() } } }
    var summaryTitle = "" { didSet { if phase != .summarizing { checkpointDraft() } } }
    private(set) var phase: Phase = .editing
    /// True while the summary fields hold a (possibly stopped) model summary.
    private(set) var hasSummary = false
    private(set) var isSummaryPartial = false
    private(set) var summarySource: String?
    var isSummaryStale: Bool { hasSummary && summarySource != trimmedTranscript }

    /// Set by the screen once the on-device model has been loaded after the sheet opened.
    @ObservationIgnored var assistant: (any JournalAssisting)?
    var modelReady: Bool
    @ObservationIgnored private(set) var summaryTask: Task<Void, Never>?

    @ObservationIgnored private let source: JournalEntry.Source
    @ObservationIgnored private let store: any JournalStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let drafts: JournalDraftStore?
    @ObservationIgnored private let draftID: UUID
    @ObservationIgnored private var suppressCheckpoint = true
    @ObservationIgnored private var discarded = false

    init(source: JournalEntry.Source, store: any JournalStore, assistant: (any JournalAssisting)?, modelReady: Bool,
         drafts: JournalDraftStore? = nil, restoring draft: JournalDraft? = nil) {
        self.source = source
        self.store = store
        self.assistant = assistant
        self.modelReady = modelReady
        self.drafts = drafts
        self.draftID = draft?.id ?? UUID()
        if let draft {
            transcript = draft.transcript
            summaryBody = draft.summaryBody
            summaryTitle = draft.summaryTitle
            summarySource = draft.summarySource
            isSummaryPartial = draft.isSummaryPartial
            hasSummary = !draft.summaryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            phase = hasSummary ? .summarized : .editing
        }
        suppressCheckpoint = false
    }

    private var trimmedTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts the summary when the text is long enough and the model is ready (once per capture).
    /// Never starts while the app is not in the foreground (GPU work in the background is refused).
    func beginIfNeeded(isForeground: Bool = true) {
        guard isForeground, phase == .editing, !hasSummary, summaryTask == nil, assistant != nil else { return }
        let input = trimmedTranscript
        guard SummaryPolicy.shouldSummarize(text: input, modelReady: modelReady) else { return }
        startSummary(input)
    }

    /// The user's 「要約する」: any non-empty text, also to re-run a summary. Needs a ready model.
    func summarize(isForeground: Bool = true) {
        guard isForeground else { return }
        switch phase {
        case .summarizing, .saving, .saved: return
        case .editing, .summarized, .failed: break
        }
        let input = trimmedTranscript
        guard modelReady, assistant != nil, !input.isEmpty else { return }
        startSummary(input)
    }

    private func startSummary(_ input: String) {
        guard let assistant else { return }
        generation += 1
        let current = generation
        phase = .summarizing
        hasSummary = false
        isSummaryPartial = false
        summarySource = input
        summaryBody = ""
        summaryTitle = ""
        checkpointDraft()
        let stream = assistant.summarize(input)
        summaryTask = Task { [weak self] in
            var raw = ""
            do {
                // Always iterated: cancelling this task ends the stream and so the model call.
                for try await chunk in stream {
                    raw += chunk
                    guard let self else { return }
                    if current == self.generation { self.show(SummaryParser.parse(raw)) }
                }
                guard let self, current == self.generation else { return }
                self.finishSummary(SummaryParser.parse(raw))
            } catch {
                guard let self, current == self.generation else { return }
                self.summaryTask = nil
                self.hasSummary = false
                self.summaryBody = ""
                self.summaryTitle = ""
                self.phase = .failed(Self.summaryFailedText)
                self.checkpointDraft()
            }
        }
    }

    /// Stops a running summary; a partial summary stays editable, otherwise back to editing.
    func stopSummary() {
        guard phase == .summarizing else { return }
        generation += 1
        summaryTask?.cancel()
        summaryTask = nil
        if summaryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasSummary = false
            isSummaryPartial = false
            summaryBody = ""
            summaryTitle = ""
            phase = .editing
        } else {
            hasSummary = true
            isSummaryPartial = true
            phase = .summarized
        }
        checkpointDraft()
    }

    /// Saves the summary with the original text, or the original text alone.
    func save(useTranscriptOnly: Bool) async {
        switch phase {
        case .saving, .saved: return
        case .summarizing: stopSummary()
        case .editing, .summarized, .failed: break
        }
        let original = trimmedTranscript
        guard !original.isEmpty else {
            phase = .failed(Self.emptyText)
            return
        }
        let body = summaryBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = summaryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard useTranscriptOnly || !isSummaryStale else {
            phase = .failed(Self.staleSummaryText)
            return
        }
        let entry: NewJournalEntry
        if hasSummary, !useTranscriptOnly, !body.isEmpty {
            entry = NewJournalEntry(
                source: source, origin: .journal, body: body, transcript: original,
                title: title.isEmpty ? nil : title, id: draftID)
        } else {
            entry = NewJournalEntry(source: source, origin: .journal, body: original, id: draftID)
        }

        phase = .saving
        do {
            _ = try await store.add(entry)
            phase = .saved
            // The entry is already saved even if cleanup fails. The stable draft id
            // makes recovery/retry return that entry instead of adding a duplicate.
            do { try drafts?.clear() } catch { /* The store exposes the cleanup error. */ }
        } catch {
            // `hasSummary` is kept, so a retry saves the same texts.
            phase = .failed(Self.saveFailedText)
        }
    }

    func checkpointDraft() {
        guard !suppressCheckpoint, !discarded, phase != .saved, phase != .saving,
              let drafts else { return }
        let draft = JournalDraft(id: draftID, source: source, transcript: transcript,
            summaryBody: summaryBody, summaryTitle: summaryTitle, summarySource: summarySource,
            isSummaryPartial: isSummaryPartial || phase == .summarizing)
        do { try drafts.save(draft) } catch { /* The store exposes the write error for retry. */ }
    }

    func discardDraft() throws {
        guard phase != .saving, phase != .saved else { return }
        stopSummary()
        try drafts?.clear()
        discarded = true
    }

    private func show(_ output: SummaryOutput) {
        summaryTitle = output.title ?? ""
        summaryBody = output.body
    }

    private func finishSummary(_ output: SummaryOutput) {
        summaryTask = nil
        show(output)
        if output.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hasSummary = false
            summaryTitle = ""
            phase = .failed(Self.summaryFailedText)
        } else {
            hasSummary = true
            isSummaryPartial = false
            phase = .summarized
        }
        checkpointDraft()
    }
}
