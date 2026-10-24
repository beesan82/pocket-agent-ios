import PocketAgentCore
import SwiftData
import SwiftUI

/// Owns the `ChatSession` for one opened conversation.
struct ChatView: View {
    let conversation: ConversationRecord
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking
    let journal: any JournalStore
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let settingsView: SettingsView

    @Environment(\.modelContext) private var modelContext
    @State private var session: ChatSession?
    @State private var broker = ApprovalBroker()

    var body: some View {
        Group {
            if let session {
                ChatContent(
                    session: session, broker: broker, settings: settings, mlxStore: mlxStore,
                    mlxRuntime: mlxRuntime, measurementLog: measurementLog, settingsView: settingsView)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil else { return }
            session = ChatSession(
                conversation: conversation,
                repository: ConversationRepository(context: modelContext),
                notes: JournalNoteStore(journal: journal),
                journal: journal,
                settings: settings,
                broker: broker,
                resolve: ChatSession.liveResolver(
                    credentials: credentials, availability: availability, settings: settings),
                onDevice: LiveOnDeviceModelAccess(store: mlxStore, runtime: mlxRuntime, availability: availability),
                log: { measurementLog.append($0) })
        }
        .stopsJournalGeneration(runtime: mlxRuntime, stop: {
            // Only the downloaded model is affected by an MLX unload or backgrounding.
            if settings.choice == .mlxLocal { session?.stop() }
        })
        .onDisappear { session?.stop() }
    }
}

private struct ChatContent: View {
    let session: ChatSession
    let broker: ApprovalBroker
    let settings: ModelSettings
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    let settingsView: SettingsView

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var isRunning: Bool { session.isBusy }

    private static let bottomID = "chat-bottom"

    /// The downloaded model is not on the device (checked before sending, or the send just failed on it).
    private var needsModelDownload: Bool {
        guard settings.choice == .mlxLocal else { return false }
        if session.lastFailureReason == .modelNotDownloaded {
            return true
        }
        return JournalModelAccess.reason(store: mlxStore, runtime: mlxRuntime) == .modelNotDownloaded
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                        TurnRow(turn: turn).id(index)
                    }
                    if !session.streamingText.isEmpty {
                        // Not saved yet, so no reply actions.
                        AssistantBubble(text: session.streamingText, showsActions: false)
                    }
                    if session.status == .loadingModel {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("モデルを読み込み中…")
                        }
                        .foregroundStyle(.secondary)
                    } else if isRunning && session.streamingText.isEmpty {
                        ProgressView("応答を待っています")
                    }
                    if case let .failed(message) = session.status {
                        Text(message).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.turns.count) {
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: session.streamingText) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { inputFocused = false }
            }
        }
        // The setter is a no-op: ApprovalSheet denies its own request by id when it disappears,
        // so closing one sheet can never deny a successor request.
        .sheet(item: Binding(get: { broker.pending }, set: { _ in })) { request in
            ApprovalSheet(request: request, broker: broker).id(request.id)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.choice.displayName).font(.caption).foregroundStyle(.secondary)
            if session.isToolSupportLimited {
                Text(ToolCapabilityTracker.limitedMessage).font(.caption).foregroundStyle(.orange)
            }
            if settings.choice == .claude {
                Text("Claude選択中: 入力・直近の会話・保存済みメモと最近の日誌はAnthropicへ送信されます")
                    .font(.caption).foregroundStyle(.orange)
            }
            if settings.choice == .mlxLocal {
                Text("ダウンロードモデル（端末内・ツールなし）: 外部へ送信しません")
                    .font(.caption).foregroundStyle(.secondary)
                if needsModelDownload {
                    NavigationLink("設定でダウンロードする") { settingsView }
                        .font(.footnote)
                }
                if mlxRuntime.state == .unloadedForMemory {
                    JournalModelStatusView(store: mlxStore, runtime: mlxRuntime, measurementLog: measurementLog)
                }
            }
            HStack(alignment: .bottom) {
                TextField("メッセージ", text: $input, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                if isRunning {
                    Button("停止", role: .destructive) { session.stop() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("送信", systemImage: "arrow.up.circle.fill") { send() }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("送信")
                        .font(.title)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let before = session.turns.count
        session.send(input)
        // Keep the text only when nothing was stored (e.g. a save failure).
        if session.turns.count > before { input = "" }
    }
}

private struct TurnRow: View {
    let turn: ChatTurn

    var body: some View {
        switch turn.role {
        case .user:
            Text(turn.text)
                .textSelection(.enabled)
                .padding(10)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            AssistantBubble(text: turn.text, showsActions: true)
        }
    }
}

private struct AssistantBubble: View {
    let text: String
    let showsActions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).textSelection(.enabled)
            if showsActions { ReplyActionsView(text: text) }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
