import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// What the journal screen hands to the capture sheet.
struct CaptureRequest: Identifiable {
    let id = UUID()
    let source: JournalEntry.Source
    let transcript: String
    var draft: JournalDraft? = nil
    var resumesDraft = false
}

/// Confirm a capture: edit the text, watch the on-device summary, save.
struct JournalCaptureView: View {
    let request: CaptureRequest
    let journal: any JournalStore
    let settings: ModelSettings
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let onSaved: () -> Void
    @Environment(JournalDraftStore.self) private var drafts

    @Environment(\.dismiss) private var dismiss
    @State private var session: JournalCaptureSession?
    @State private var manualTask: Task<Void, Never>?
    /// The first load and automatic summary; cancelled when the app leaves the foreground.
    @State private var startTask: Task<Void, Never>?
    @State private var isForeground = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmDiscard = false

    /// Follows Settings: Apple when chosen and usable, otherwise the downloaded model. Never Claude.
    private var backend: JournalBackend {
        JournalModelAccess.backend(settings: settings, availability: availability)
    }

    /// Text that would be lost on close; the sheet only closes after asking.
    private var hasUnsavedText: Bool {
        !(session?.transcript ?? request.transcript).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    CaptureForm(
                        session: session, mlxStore: mlxStore, mlxRuntime: mlxRuntime,
                        measurementLog: measurementLog, backend: backend,
                        showsAppleFallbackNote: JournalModelAccess.usesDownloadedInsteadOfApple(
                            settings: settings, backend: backend),
                        onSummarize: summarizeManually)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(request.source == .voice ? "音声の記録" : "テキストの記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        if hasUnsavedText { confirmDiscard = true } else { dismiss() }
                    }
                    .disabled(session?.phase == .saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("後で続ける") {
                        stopGeneration()
                        session?.checkpointDraft()
                        if drafts.errorMessage == nil { dismiss() }
                    }
                    .disabled(session == nil || session?.phase == .saving)
                }
            }
            .confirmationDialog(
                "この記録を破棄しますか？（保存されません）", isPresented: $confirmDiscard, titleVisibility: .visible
            ) {
                Button("破棄", role: .destructive) {
                    stopGeneration()
                    do {
                        if let session { try session.discardDraft() } else { try drafts.clear() }
                        dismiss()
                    } catch { /* The draft error stays visible. */ }
                }
                Button("戻る", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(session?.phase == .saving || hasUnsavedText)
        .stopsJournalGeneration(runtime: mlxRuntime) { stopGeneration() }
        .task {
            isForeground = scenePhase == .active
            guard startTask == nil else { return }
            startTask = Task { await start() }
        }
        .onChange(of: scenePhase) { _, phase in isForeground = phase == .active }
        .onChange(of: session?.phase) { _, phase in
            if phase == .saved {
                onSaved()
                dismiss()
            }
        }
        .onDisappear {
            stopGeneration()
            session?.checkpointDraft()
        }
    }

    /// Ends a model load started by 「要約する」 and a running summary; the texts stay.
    private func stopGeneration() {
        startTask?.cancel()
        manualTask?.cancel()
        manualTask = nil
        session?.stopSummary()
    }

    /// 「要約する」: loads the downloaded model if needed (Apple needs no load), then summarizes
    /// without the length threshold.
    private func summarizeManually() {
        guard let session else { return }
        manualTask?.cancel()
        let current = backend
        manualTask = Task {
            let client = await JournalModelAccess.client(current, store: mlxStore, runtime: mlxRuntime)
            guard !Task.isCancelled else { return }
            manualTask = nil
            guard let client else { return }
            session.assistant = JournalModelAccess.assistant(client: client, backend: current)
            session.modelReady = true
            session.summarize(isForeground: isForeground)
        }
    }

    private func start() async {
        guard session == nil else { return }
        let current = backend
        let client = JournalModelAccess.readyClient(current, store: mlxStore, runtime: mlxRuntime)
        let created = JournalCaptureSession(
            source: request.source, store: journal,
            assistant: client.map { JournalModelAccess.assistant(client: $0, backend: current) },
            modelReady: client != nil, drafts: drafts, restoring: request.draft)
        if request.draft == nil { created.transcript = request.transcript }
        session = created
        created.checkpointDraft()
        // Recovery is explicit; restarting the app never starts inference by itself.
        guard !request.resumesDraft else { return }
        if client != nil {
            created.beginIfNeeded(isForeground: isForeground)
            return
        }
        // Long enough to summarize: load the downloaded model once, then summarize.
        let trimmed = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SummaryPolicy.shouldSummarize(text: trimmed, modelReady: true) else { return }
        guard let loaded = await JournalModelAccess.client(current, store: mlxStore, runtime: mlxRuntime),
              !Task.isCancelled, created.phase == .editing
        else { return }
        created.assistant = JournalModelAccess.assistant(client: loaded, backend: current)
        created.modelReady = true
        created.beginIfNeeded(isForeground: isForeground)
    }
}

private struct CaptureForm: View {
    @Environment(JournalDraftStore.self) private var drafts
    @Bindable var session: JournalCaptureSession
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let backend: JournalBackend
    let showsAppleFallbackNote: Bool
    let onSummarize: () -> Void

    private var isSummarizing: Bool { session.phase == .summarizing }
    private var isBusy: Bool { session.phase == .saving }
    /// Apple, or the downloaded model loaded or loadable on tap; otherwise the status view shows why not.
    private var canSummarize: Bool {
        JournalModelAccess.isReady(backend, store: mlxStore, runtime: mlxRuntime)
            || JournalModelAccess.reason(backend, store: mlxStore, runtime: mlxRuntime) == nil
    }
    private var isLoading: Bool { backend == .mlxLocal && mlxRuntime.state == .loading }

    var body: some View {
        Form {
            if let message = drafts.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("下書き保存を再試行") { session.checkpointDraft() }
                }
            }
            Section("本文") {
                TextEditor(text: $session.transcript)
                    .frame(minHeight: 120)
                    .disabled(isBusy)
            }

            if isSummarizing || session.hasSummary {
                Section {
                    if session.isSummaryStale {
                        Text(JournalCaptureSession.staleSummaryText).foregroundStyle(.orange)
                    }
                    if session.isSummaryPartial {
                        Text("途中で停止した要約です。内容を確認してから保存してください。")
                            .foregroundStyle(.orange)
                    }
                    TextField("見出し", text: $session.summaryTitle)
                        .disabled(isSummarizing || isBusy)
                    TextEditor(text: $session.summaryBody)
                        .frame(minHeight: 80)
                        .disabled(isSummarizing || isBusy)
                    if isSummarizing {
                        HStack {
                            ProgressView()
                            Text("要約しています…").foregroundStyle(.secondary)
                            Spacer()
                            Button("停止", role: .destructive) { session.stopSummary() }
                        }
                    }
                } header: {
                    Text("要約（端末内モデル）")
                } footer: {
                    Text("「保存」で要約を本文として、原文と一緒に保存します。")
                }
            }

            if !isSummarizing {
                Section {
                    Button("要約する") { onSummarize() }
                        .disabled(isBusy || isEmpty || !canSummarize || isLoading)
                    JournalModelStatusView(
                        store: mlxStore, runtime: mlxRuntime, measurementLog: measurementLog,
                        linksToModelManagement: false, backend: backend,
                        showsAppleFallbackNote: showsAppleFallbackNote)
                    if !canSummarize {
                        Text("要約せずに保存できます。").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("要約")
                } footer: {
                    Text("要約は端末内のモデルで行い、外部へ送信しません。")
                }
            }

            if case let .failed(text) = session.phase {
                Section {
                    Text(text).foregroundStyle(.red)
                }
            }

            Section {
                Button("保存") { save(useTranscriptOnly: false) }
                    .disabled(isBusy || isSummarizing || isEmpty || session.isSummaryStale)
                Button("原文のまま保存") { save(useTranscriptOnly: true) }
                    .disabled(isBusy || isEmpty)
            }
        }
    }

    private var isEmpty: Bool {
        session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(useTranscriptOnly: Bool) {
        Task { await session.save(useTranscriptOnly: useTranscriptOnly) }
    }
}
