import PocketAgentCore
import SwiftUI

/// Home: the journal by day (newest first), search, and recording by voice or text.
struct JournalView: View {
    @Environment(JournalDraftStore.self) private var drafts
    let journal: any JournalStore
    let settings: ModelSettings
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let settingsView: SettingsView

    @State private var entries: [JournalEntry] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var confirmDiscardDraft = false
    @State private var resumingDraft = false
    @State private var listError: String?
    /// Kept apart from `listError` so the reload after a failed delete does not hide it.
    @State private var deleteError: String?
    @State private var speech = SpeechCapture()
    @State private var speechMessage: String?
    @State private var confirmInstall = false
    @State private var capture: CaptureRequest?
    @State private var reloadToken = 0
    @FocusState private var inputFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List {
            if let draft = drafts.draft {
                Section("保存前の下書き") {
                    Text(String(draft.transcript.prefix(80))).lineLimit(3)
                    Button("下書きを再開") { resumeDraft(draft) }.disabled(isRecordingBusy)
                    Button("下書きを破棄", role: .destructive) { confirmDiscardDraft = true }
                        .disabled(isRecordingBusy)
                }
            }
            if let message = drafts.errorMessage {
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("下書きを破棄", role: .destructive) { confirmDiscardDraft = true }
                }
            }
            if let listError {
                Text(listError).foregroundStyle(.red)
            }
            if let deleteError {
                Text(deleteError).foregroundStyle(.red)
            }
            if loaded, entries.isEmpty, listError == nil {
                Text(isSearching ? "見つかりませんでした。" : "日誌はまだありません。下の録音ボタンかテキスト欄から記録しましょう。")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections, id: \.day) { section in
                Section(section.day.formatted(.dateTime.year().month().day().weekday())) {
                    ForEach(section.entries) { entry in
                        NavigationLink {
                            JournalEntryDetailView(entry: entry)
                        } label: {
                            JournalRow(entry: entry)
                        }
                        // A push would end the recording (onDisappear).
                        .disabled(isRecordingBusy)
                    }
                    .onDelete { offsets in delete(offsets.map { section.entries[$0].id }) }
                }
            }
        }
        .navigationTitle("日誌")
        .searchable(text: $query, prompt: "日誌を検索")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { inputFocused = false }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    settingsView
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
                .disabled(isRecordingBusy)
            }
        }
        .safeAreaInset(edge: .bottom) { recorder }
        .task(id: TaskKey(query: query, token: reloadToken)) { await reload() }
        .task { await speech.refreshAvailability() }
        .sheet(item: $capture, onDismiss: { drafts.pauseComposer() }) { request in
            JournalCaptureView(
                request: request, journal: journal, settings: settings, availability: availability,
                mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog
            ) {
                reloadToken += 1
            }
        }
        .confirmationDialog(
            "日本語の音声認識データをダウンロードしますか？（通信が発生します）",
            isPresented: $confirmInstall, titleVisibility: .visible
        ) {
            Button("ダウンロード") { installAssets() }
            Button("キャンセル", role: .cancel) {}
        }
        .onDisappear { stopRecordingOnLeave() }
        .confirmationDialog("下書きを破棄しますか？", isPresented: $confirmDiscardDraft, titleVisibility: .visible) {
            Button("破棄", role: .destructive) {
                do { try drafts.clear() }
                catch { /* The draft error is shown above. */ }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var hasOtherDraft: Bool {
        drafts.hasOtherDraft || resumingDraft
    }

    private func resumeDraft(_ draft: JournalDraft) {
        guard !resumingDraft, drafts.draft?.id == draft.id else { return }
        resumingDraft = true
        Task {
            defer { resumingDraft = false }
            do {
                if let current = try await drafts.resumeDraft(lookup: { try await journal.entry(id: $0) }) {
                    capture = CaptureRequest(source: current.source, transcript: current.transcript,
                        draft: current, resumesDraft: true)
                } else {
                    reloadToken += 1
                }
            } catch { listError = "下書きを開けませんでした。もう一度お試しください。" }
        }
    }

    // MARK: List

    private struct TaskKey: Equatable {
        let query: String
        let token: Int
    }

    private struct DaySection {
        let day: Date
        let entries: [JournalEntry]
    }

    /// Entries arrive newest first; grouping keeps that order in each day.
    private var sections: [DaySection] {
        let calendar = Calendar.current
        var result: [DaySection] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if let last = result.last, last.day == day {
                result[result.count - 1] = DaySection(day: day, entries: last.entries + [entry])
            } else {
                result.append(DaySection(day: day, entries: [entry]))
            }
        }
        return result
    }

    private func reload() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Debounce typing; a newer key cancels this task.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        do {
            let found = trimmed.isEmpty ? try await journal.all() : try await journal.search(trimmed)
            guard !Task.isCancelled else { return }
            entries = found
            listError = nil
        } catch {
            guard !Task.isCancelled else { return }
            listError = "日誌を読み込めませんでした。"
        }
        loaded = true
    }

    private func delete(_ ids: [UUID]) {
        let journal = journal
        Task {
            do {
                for id in ids { _ = try await journal.delete(id: id) }
                deleteError = nil
            } catch {
                deleteError = "日誌を削除できませんでした。"
            }
            // Reload either way: a partial delete must show what is really left.
            reloadToken += 1
        }
    }

    // MARK: Recording

    private var isRecordingBusy: Bool {
        switch speech.state {
        case .preparing, .recording, .finishing: true
        case .idle, .failed: false
        }
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = speech.reason, !isRecordingBusy {
                Text(reason.userMessage).font(.footnote).foregroundStyle(.secondary)
                switch reason {
                case .assetsNotInstalled, .languageAssetsNotInstalled:
                    Button("音声データを入手") { confirmInstall = true }.font(.footnote)
                case .permissionDenied:
                    Button("マイクと音声認識を許可") {
                        Task { await speech.requestPermissions() }
                    }
                    .font(.footnote)
                case .moduleUnavailable, .japaneseUnsupported, .languageUnsupported:
                    EmptyView()
                }
            }
            if case let .failed(text) = speech.state {
                Text(text).font(.footnote).foregroundStyle(.red)
            }
            if let speechMessage {
                Text(speechMessage).font(.footnote).foregroundStyle(.red)
            }
            if isRecordingBusy {
                // Final text dark, the tentative tail light.
                Text("\(speech.finalText)\(Text(speech.volatileText).foregroundStyle(.secondary))")
                    .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                recordButton
                TextField("テキストで記録", text: Binding(get: { drafts.composerText },
                    set: { drafts.editComposer($0) }), axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRecordingBusy || hasOtherDraft)
                Button("記録") { recordText() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRecordingBusy || hasOtherDraft || drafts.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var recordButton: some View {
        switch speech.state {
        case .recording:
            Button { stopRecording() } label: {
                Image(systemName: "stop.circle.fill").font(.title)
            }
            .tint(.red)
            .accessibilityLabel("録音を停止")
        case .preparing, .finishing:
            ProgressView().frame(width: 34, height: 34)
                .accessibilityLabel("音声入力を準備中")
        case .idle, .failed:
            Button { startRecording() } label: {
                Image(systemName: "mic.circle.fill").font(.title)
            }
            .disabled(speech.reason != nil || drafts.draft != nil || drafts.errorMessage != nil)
            .accessibilityLabel("録音")
            .accessibilityHint(speech.reason?.userMessage ?? "")
        }
    }

    private func recordText() {
        inputFocused = false
        let text = drafts.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        capture = CaptureRequest(source: .text, transcript: text, draft: drafts.draft)
    }

    private func startRecording() {
        inputFocused = false
        speechMessage = nil
        Task {
            do {
                try await speech.start()
            } catch {
                speechMessage = SpeechCapture.startFailedText
            }
        }
    }

    private func stopRecording() {
        let wasRecording = speech.state == .recording
        Task {
            await speech.stop()
            openCaptureFromSpeech(wasRecording: wasRecording)
        }
    }

    /// Leaving the tab ends the recording; what was recognized still opens for saving.
    private func stopRecordingOnLeave() {
        guard isRecordingBusy else { return }
        let wasRecording = speech.state == .recording
        Task {
            await speech.stop()
            openCaptureFromSpeech(wasRecording: wasRecording)
        }
    }

    /// Stopped during preparation (nothing recorded): just back to idle, no message.
    private func openCaptureFromSpeech(wasRecording: Bool) {
        guard wasRecording else { return }
        guard case .idle = speech.state else { return }  // a failure is shown by `speech.state`
        let text = speech.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            speechMessage = "音声を認識できませんでした。もう一度お試しください。"
            return
        }
        capture = CaptureRequest(source: .voice, transcript: text)
    }

    private func installAssets() {
        Task {
            do {
                try await speech.installAssets()
                speechMessage = nil
            } catch {
                speechMessage = SpeechCapture.installFailedText
            }
        }
    }
}

private struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.source == .voice ? "mic" : "text.alignleft")
                .foregroundStyle(.secondary)
                .accessibilityLabel(entry.source == .voice ? "音声" : "テキスト")
            VStack(alignment: .leading, spacing: 4) {
                if let title = entry.title, !title.isEmpty {
                    Text(title).font(.headline).lineLimit(1)
                }
                Text(entry.body).lineLimit(2)
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One entry in full, with the original text when the body is a summary.
struct JournalEntryDetailView: View {
    let entry: JournalEntry

    var body: some View {
        List {
            Section {
                Text(entry.body).textSelection(.enabled)
            } header: {
                Text(entry.createdAt.formatted(date: .long, time: .shortened))
            }
            if let transcript = entry.transcript, !transcript.isEmpty {
                Section("原文") {
                    Text(transcript).textSelection(.enabled)
                }
            }
            Section {
                Label(
                    entry.source == .voice ? "音声で記録" : "テキストで記録",
                    systemImage: entry.source == .voice ? "mic" : "text.alignleft")
                if entry.origin == .noteTool {
                    Text("チャットのメモ機能で保存").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(entry.title ?? "日誌")
        .navigationBarTitleDisplayMode(.inline)
    }
}
