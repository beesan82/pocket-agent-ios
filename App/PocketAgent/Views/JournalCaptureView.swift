import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// What the journal screen hands to the capture sheet.
struct CaptureRequest: Identifiable {
    let id = UUID()
    let source: JournalEntry.Source
    let transcript: String
}

/// Confirm a capture: edit the text, watch the on-device summary, save.
struct JournalCaptureView: View {
    let request: CaptureRequest
    let journal: any JournalStore
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: JournalCaptureSession?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    CaptureForm(
                        session: session, mlxStore: mlxStore, mlxRuntime: mlxRuntime,
                        measurementLog: measurementLog)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(request.source == .voice ? "音声の記録" : "テキストの記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(session?.phase == .saving)
        .task { await start() }
        .onChange(of: session?.phase) { _, phase in
            if phase == .saved {
                onSaved()
                dismiss()
            }
        }
        .onDisappear { session?.stopSummary() }
    }

    private func start() async {
        guard session == nil else { return }
        let client = mlxRuntime.client
        let created = JournalCaptureSession(
            source: request.source, store: journal,
            assistant: client.map { JournalAssistant(client: $0) }, modelReady: client != nil)
        created.transcript = request.transcript
        session = created
        if client != nil {
            created.beginIfNeeded()
            return
        }
        // Long enough to summarize: load the downloaded model once, then summarize.
        let trimmed = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SummaryPolicy.shouldSummarize(text: trimmed, modelReady: true) else { return }
        guard let loaded = await JournalModelAccess.client(store: mlxStore, runtime: mlxRuntime),
              !Task.isCancelled, created.phase == .editing
        else { return }
        created.assistant = JournalAssistant(client: loaded)
        created.modelReady = true
        created.beginIfNeeded()
    }
}

private struct CaptureForm: View {
    @Bindable var session: JournalCaptureSession
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog

    private var isSummarizing: Bool { session.phase == .summarizing }
    private var isBusy: Bool { session.phase == .saving }
    private var isLong: Bool {
        session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= SummaryPolicy.autoSummarizeThreshold
    }

    var body: some View {
        Form {
            Section("本文") {
                TextEditor(text: $session.transcript)
                    .frame(minHeight: 120)
                    .disabled(isBusy)
            }

            if isSummarizing || session.hasSummary {
                Section {
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
            } else if isLong && session.phase == .editing {
                Section("要約") {
                    JournalModelStatusView(store: mlxStore, runtime: mlxRuntime, measurementLog: measurementLog)
                    if mlxRuntime.client == nil, mlxRuntime.state != .loading {
                        Text("要約せずに保存できます。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if case let .failed(text) = session.phase {
                Section {
                    Text(text).foregroundStyle(.red)
                }
            }

            Section {
                Button("保存") { save(useTranscriptOnly: false) }
                    .disabled(isBusy || isSummarizing || isEmpty)
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
