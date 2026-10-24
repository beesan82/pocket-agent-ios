import PocketAgentCore
import PocketAgentRuntime
import SwiftUI
import Translation

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
    /// Two languages (ja/en) for the next meeting, remembered between launches.
    /// The meeting's languages, remembered between launches: language 1, and language 2 ("" = none).
    @AppStorage("meeting.language1") private var language1 = "ja"
    @AppStorage("meeting.language2") private var language2 = ""
    @State private var translationInstalled = false
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationMessage: String?

    private var chosenLanguages: [String] {
        language2.isEmpty || language2 == language1 ? [language1] : [language1, language2]
    }

    /// "日本語・English" for the meeting's languages.
    private var languageNames: String {
        meeting.languages.map { MeetingLanguage.named($0)?.displayName ?? $0 }.joined(separator: "・")
    }

    private var translationMissingText: String {
        "翻訳データ（\(languageNames)）を入手すると訳が付きます。"
    }
    static let translationDownloadFailedText = "翻訳データを入手できませんでした。通信環境を確認して再試行してください。"

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
        .task {
            migrateBilingualSetting()
            meeting.setLanguages(chosenLanguages)
            await meeting.source.refreshAvailability()
            await refreshTranslation()
        }
        .onChange(of: language1) { _, value in
            if language2 == value { language2 = "" }
        }
        .onChange(of: chosenLanguages) { _, value in
            meeting.setLanguages(value)
            Task {
                await meeting.source.refreshAvailability()
                await refreshTranslation()
            }
        }
        // Downloading a language pair needs a view's session (the consent sheet).
        .translationTask(translationConfig) { session in
            do {
                try await Self.prepare(SessionBox(session: session))
                translationMessage = nil
            } catch {
                translationMessage = Self.translationDownloadFailedText
            }
            await refreshTranslation()
            translationConfig = nil
        }
        .stopsJournalGeneration(runtime: mlxRuntime) { meeting.stopNotesUpdate() }
        .confirmationDialog(
            "\(languageNames)の音声認識データをダウンロードします（通信が発生します）",
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
            languagePickers
                .padding(.horizontal, 40)
            speechAvailability
            if meeting.bilingual {
                translationAvailability
            }
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
                case .assetsNotInstalled, .languageAssetsNotInstalled:
                    Button("音声データを入手") { confirmInstall = true }.font(.footnote)
                case .permissionDenied:
                    Button("マイクと音声認識を許可") {
                        Task { await meeting.source.requestPermissions() }
                    }
                    .font(.footnote)
                case .moduleUnavailable, .japaneseUnsupported, .languageUnsupported:
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
    private var translationAvailability: some View {
        VStack(spacing: 8) {
            if translationInstalled {
                Text("翻訳: \(languageNames) 導入済み").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(translationMissingText).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("翻訳データを入手（\(languageNames)）") { requestTranslationDownload() }
                    .font(.footnote)
                    .disabled(translationConfig != nil)
            }
            if let translationMessage {
                Text(translationMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
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
            if meeting.bilingual, meeting.translator == nil {
                Text(translationMissingText).font(.footnote).foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            Divider().padding(.top, 12)
            if meeting.bilingual {
                bilingualTranscript
            } else {
                transcriptList
            }
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

    /// 2 columns: left all Japanese (originals and translations), right all English. One row per
    /// utterance; the original's cell is bold, a translation still on its way shows "…".
    private var bilingualTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(meeting.languages, id: \.self) { code in
                            Text(MeetingLanguage.named(code)?.displayName ?? code)
                                .font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .foregroundStyle(.secondary)
                    ForEach(meeting.segments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MeetingTranscriptFormatter.timestamp(segment.offset))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(meeting.languages, id: \.self) { code in
                                    cell(for: segment, column: code)
                                }
                            }
                        }
                        .id(segment.id)
                    }
                    if !meeting.volatileText.isEmpty {
                        Text(meeting.volatileText).foregroundStyle(.secondary)
                    }
                    if meeting.segments.isEmpty, meeting.volatileText.isEmpty {
                        Text("どちらの言語でも、話し始めるとここに流れます。").foregroundStyle(.secondary)
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

    private func cell(for segment: TranscriptSegment, column: String) -> some View {
        let isOriginal = segment.language == column
        // "…" only while a translation is still coming; otherwise the cell stays empty.
        let text = isOriginal
            ? segment.text
            : (segment.translation ?? (meeting.isAwaitingTranslation(segment) ? "…" : ""))
        return Text(text)
            .fontWeight(isOriginal ? .semibold : .regular)
            .foregroundStyle(isOriginal || segment.translation != nil ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private var languagePickers: some View {
        VStack(spacing: 4) {
            Picker("言語 1", selection: $language1) {
                ForEach(MeetingLanguage.all) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            Picker("言語 2", selection: $language2) {
                Text("なし").tag("")
                ForEach(MeetingLanguage.all.filter { $0.code != language1 }) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
        }
        .pickerStyle(.menu)
    }

    /// The earlier 「二言語（日本語・English）」 switch: ON becomes language 2 = English, once.
    private func migrateBilingualSetting() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "meeting.bilingual") != nil else { return }
        if defaults.bool(forKey: "meeting.bilingual"), defaults.object(forKey: "meeting.language2") == nil {
            language2 = "en"
        }
        defaults.removeObject(forKey: "meeting.bilingual")
    }

    private func refreshTranslation() async {
        guard meeting.bilingual, let first = meeting.languages.first, let second = meeting.languages.last else { return }
        let forward = await AppleTranslator.isInstalled(from: first, to: second)
        let backward = await AppleTranslator.isInstalled(from: second, to: first)
        translationInstalled = forward && backward
    }

    /// One direction per consent sheet; the button stays until both directions are installed.
    private func requestTranslationDownload() {
        translationMessage = nil
        guard let first = meeting.languages.first, let second = meeting.languages.last, first != second else { return }
        Task {
            let forward = await AppleTranslator.isInstalled(from: first, to: second)
            let (source, target) = forward ? (second, first) : (first, second)
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        }
    }

    /// The view's session only presents the consent sheet; it is used once, here.
    private struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
    }

    @concurrent
    private nonisolated static func prepare(_ box: SessionBox) async throws {
        try await box.session.prepareTranslation()
    }

    private func startMeeting() {
        speechMessage = nil
        modelTask?.cancel()
        let current = backend
        modelTask = Task {
            if meeting.bilingual {
                await refreshTranslation()
                meeting.translator = translationInstalled ? AppleTranslator() : nil
            }
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
