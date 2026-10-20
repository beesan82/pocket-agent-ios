import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// "Ask the journal" with the on-device model. Nothing here leaves the device.
struct AskJournalView: View {
    let journal: any JournalStore
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let settingsView: SettingsView

    @State private var session: AskSession
    @State private var question = ""
    @State private var preparing = false
    @State private var prepareTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    init(
        journal: any JournalStore, mlxStore: MLXModelStore, mlxRuntime: MLXRuntime,
        measurementLog: MeasurementLog, settingsView: SettingsView
    ) {
        self.journal = journal
        self.mlxStore = mlxStore
        self.mlxRuntime = mlxRuntime
        self.measurementLog = measurementLog
        self.settingsView = settingsView
        _session = State(initialValue: AskSession(store: journal, assistant: nil))
    }

    private var isBusy: Bool { preparing || session.isRunning }
    private var canAsk: Bool {
        !isBusy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (JournalModelAccess.readyClient(store: mlxStore, runtime: mlxRuntime) != nil
                || JournalModelAccess.reason(store: mlxStore, runtime: mlxRuntime) == nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("例: 先週なにしてた？", text: $question)
                    .focused($inputFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        if canAsk { ask() }
                        inputFocused = false
                    }
                    .disabled(isBusy)
                if isBusy {
                    Button("停止", role: .destructive) { stop() }
                } else {
                    Button("聞く") { ask() }
                        .disabled(!canAsk)
                }
                if JournalModelAccess.readyClient(store: mlxStore, runtime: mlxRuntime) == nil {
                    JournalModelStatusView(store: mlxStore, runtime: mlxRuntime, measurementLog: measurementLog)
                }
            } header: {
                Text("質問")
            } footer: {
                Text("日誌の内容は端末内のモデルだけで扱い、外部へ送信しません。")
            }

            if session.phase != .idle {
                answerSection
            }

            if !session.evidence.isEmpty {
                Section("根拠にした日誌") {
                    ForEach(session.evidence, id: \.entry.id) { packed in
                        NavigationLink {
                            JournalEntryDetailView(entry: packed.entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(packed.entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(String(packed.entry.body.prefix(60))).lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("日誌に聞く")
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
            }
        }
        .onAppear { mlxStore.refresh() }
        .stopsJournalGeneration(runtime: mlxRuntime) { stop() }
        .onDisappear { stop() }
    }

    private var answerSection: some View {
        Section("回答") {
            if session.usedRecentFallback {
                Text("該当する日誌が見つからなかったため、直近の日誌から答えています。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if session.phase == .searching {
                HStack {
                    ProgressView()
                    Text("日誌を探しています…").foregroundStyle(.secondary)
                }
            }
            if !session.answer.isEmpty {
                Text(session.answer).textSelection(.enabled)
            } else if session.phase == .answering {
                ProgressView()
            }
            if session.phase == .stopped {
                Text("（停止しました）").foregroundStyle(.secondary)
            }
            if case let .failed(text) = session.phase {
                Text(text).foregroundStyle(.red)
            }
        }
    }

    private func ask() {
        inputFocused = false
        let text = question
        prepareTask?.cancel()
        preparing = true
        prepareTask = Task {
            // Loads the downloaded model when needed; the assistant is built from the current client.
            let client = await JournalModelAccess.client(store: mlxStore, runtime: mlxRuntime)
            guard !Task.isCancelled else { return }  // stop() already reset the state
            preparing = false
            prepareTask = nil
            guard let client else { return }
            session.assistant = JournalModelAccess.assistant(client: client)
            session.ask(text)
        }
    }

    private func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        preparing = false
        session.stop()
    }
}
