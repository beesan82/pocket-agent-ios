import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// 会議: live on-device transcription, notes rewritten on device as the meeting goes,
/// one journal entry at the end. Nothing here leaves the device.
struct MeetingView: View {
    let meeting: MeetingSession
    let settings: ModelSettings
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let settingsView: SettingsView

    @State private var speechMessage: String?
    @State private var confirmInstall = false
    @State private var modelTask: Task<Void, Never>?

    private var backend: JournalBackend {
        JournalModelAccess.backend(settings: settings, availability: availability)
    }

    var body: some View {
        Group {
            switch meeting.state {
            case .idle, .saved, .failed:
                startScreen
            case .preparing, .recording, .paused, .finishing:
                liveScreen
            }
        }
        .navigationTitle("会議")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    settingsView
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
        }
        .task { await meeting.source.refreshAvailability() }
        .stopsJournalGeneration(runtime: mlxRuntime) { meeting.stopNotesUpdate() }
        .confirmationDialog(
            "日本語の音声認識データをダウンロードします（通信が発生します）",
            isPresented: $confirmInstall, titleVisibility: .visible
        ) {
            Button("ダウンロード") { installAssets() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: Start

    private var startScreen: some View {
        VStack(spacing: 20) {
            Spacer()
            switch meeting.state {
            case .saved:
                Label("日誌に保存しました", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case let .failed(text):
                Text(text).foregroundStyle(.red).multilineTextAlignment(.center)
                if text == MeetingSession.saveFailedText {
                    Button("もう一度保存") { Task { await meeting.retrySave() } }
                        .buttonStyle(.bordered)
                }
            default:
                EmptyView()
            }
            Button {
                startMeeting()
            } label: {
                Label("会議を開始", systemImage: "waveform")
                    .font(.title2)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(meeting.source.reason != nil)
            speechAvailability
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("音声は端末内で文字に起こし、要点も端末内のモデルが書きます。外部へは送信しません。ロック中も録音は続きます。")
                    .font(.footnote).foregroundStyle(.secondary)
                modelStatus
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var speechAvailability: some View {
        if let reason = meeting.source.reason {
            VStack(spacing: 8) {
                Text(reason.userMessage).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                switch reason {
                case .assetsNotInstalled, .englishAssetsNotInstalled:
                    Button("音声データを入手") { confirmInstall = true }.font(.footnote)
                case .permissionDenied:
                    Button("マイクと音声認識を許可") {
                        Task { await meeting.source.requestPermissions() }
                    }
                    .font(.footnote)
                case .moduleUnavailable, .japaneseUnsupported, .englishUnsupported:
                    EmptyView()
                }
            }
            .padding(.horizontal)
        }
        if let speechMessage {
            Text(speechMessage).font(.footnote).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        let current = backend
        let fallsBack = JournalModelAccess.usesDownloadedInsteadOfApple(settings: settings, backend: current)
        if fallsBack || !JournalModelAccess.isReady(current, store: mlxStore, runtime: mlxRuntime) {
            JournalModelStatusView(
                store: mlxStore, runtime: mlxRuntime, measurementLog: measurementLog,
                backend: current, showsAppleFallbackNote: fallsBack)
        }
    }

    // MARK: Live

    private var liveScreen: some View {
        VStack(spacing: 0) {
            header
                .padding()
            notesCard
                .padding(.horizontal)
            Divider().padding(.top, 12)
            transcriptList
        }
    }

    private var header: some View {
        HStack {
            if let startedAt = meeting.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(MeetingTranscriptFormatter.timestamp(context.date.timeIntervalSince(startedAt)))
                        .font(.title2.monospacedDigit())
                }
            }
            switch meeting.state {
            case .recording:
                Image(systemName: "record.circle").foregroundStyle(.red)
                    .accessibilityLabel("録音中")
            case .preparing:
                ProgressView()
            case .finishing:
                ProgressView()
                Text("保存しています…").font(.footnote).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Spacer()
            if meeting.state != .finishing {
                Button("終了", role: .destructive) { Task { await meeting.finish() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("要点").font(.headline)
                Spacer()
                if meeting.pendingCharacters > 0 {
                    Text("未反映 \(meeting.pendingCharacters) 文字").font(.caption).foregroundStyle(.secondary)
                }
                if meeting.notesPhase == .updating {
                    Button("停止") { meeting.stopNotesUpdate() }.font(.footnote)
                } else {
                    Button("更新") { meeting.updateNotesNow() }
                        .font(.footnote)
                        .disabled(!MeetingNotesPolicy.shouldManualUpdate(
                            pendingCharacters: meeting.pendingCharacters, modelReady: meeting.modelReady,
                            isUpdating: false))
                }
            }
            if case let .paused(text) = meeting.state {
                HStack {
                    Text(text).font(.footnote).foregroundStyle(.red)
                    Button("再開") { Task { await meeting.resume() } }.font(.footnote)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if meeting.notesPhase == .updating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("要点を更新中…").font(.footnote).foregroundStyle(.secondary)
                        }
                        if !meeting.draftNotes.isEmpty {
                            Text(meeting.draftNotes).font(.footnote).foregroundStyle(.secondary)
                        } else if !meeting.notes.isEmpty {
                            Text(meeting.notes).font(.footnote)
                        }
                    } else if meeting.notes.isEmpty {
                        Text(meeting.modelReady ? "要点はまだありません" : "要点はモデルを読み込むと付きます")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(meeting.notes).font(.footnote)
                    }
                    if case let .failed(text) = meeting.notesPhase {
                        Text(text).font(.footnote).foregroundStyle(.red)
                    }
                    if !meeting.modelReady {
                        modelStatus
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .padding()
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(meeting.segments) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            Text(MeetingTranscriptFormatter.timestamp(segment.offset))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(segment.text)
                        }
                        .id(segment.id)
                    }
                    if !meeting.volatileText.isEmpty {
                        Text(meeting.volatileText).foregroundStyle(.secondary)
                    }
                    if meeting.segments.isEmpty, meeting.volatileText.isEmpty {
                        Text("話し始めると、ここに文字が流れます。").foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: meeting.segments.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Actions

    private func startMeeting() {
        speechMessage = nil
        modelTask?.cancel()
        let current = backend
        modelTask = Task {
            // Recording first; the model (Apple at once, the downloaded one after a load) follows.
            await meeting.start()
            guard !Task.isCancelled else { return }
            if case .failed = meeting.state { return }
            meeting.batchCharacterBudget = JournalModelRule.contextCharacterBudget(for: current)
            if let ready = JournalModelAccess.readyClient(current, store: mlxStore, runtime: mlxRuntime) {
                meeting.assistant = JournalModelAccess.assistant(client: ready, backend: current)
                return
            }
            let client = await JournalModelAccess.client(current, store: mlxStore, runtime: mlxRuntime)
            guard !Task.isCancelled, let client else { return }
            meeting.assistant = JournalModelAccess.assistant(client: client, backend: current)
        }
    }

    private func installAssets() {
        Task {
            do {
                try await meeting.source.installAssets()
                speechMessage = nil
            } catch {
                speechMessage = SpeechCapture.installFailedText
            }
        }
    }
}
