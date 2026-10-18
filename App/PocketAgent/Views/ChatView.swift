import PocketAgentCore
import SwiftData
import SwiftUI

/// Owns the `ChatSession` for one opened conversation.
struct ChatView: View {
    let conversation: ConversationRecord
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking

    @Environment(\.modelContext) private var modelContext
    @State private var session: ChatSession?
    @State private var broker = ApprovalBroker()

    var body: some View {
        Group {
            if let session {
                ChatContent(session: session, broker: broker, settings: settings)
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
                notes: SwiftDataNoteStore(modelContainer: modelContext.container),
                settings: settings,
                broker: broker,
                resolve: ChatSession.liveResolver(
                    credentials: credentials, availability: availability, settings: settings))
        }
        .onDisappear { session?.stop() }
    }
}

private struct ChatContent: View {
    let session: ChatSession
    let broker: ApprovalBroker
    let settings: ModelSettings

    @State private var input = ""

    private var isRunning: Bool { session.status == .running }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                        TurnRow(turn: turn).id(index)
                    }
                    if isRunning {
                        ProgressView("応答を待っています")
                    }
                    if case let .failed(message) = session.status {
                        Text(message).foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .onChange(of: session.turns.count) {
                withAnimation { proxy.scrollTo(session.turns.count - 1, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .sheet(item: Binding(get: { broker.pending }, set: { if $0 == nil { broker.answer(.deny(reason: nil)) } })) { request in
            ApprovalSheet(request: request, broker: broker).id(request.id)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(settings.choice.displayName).font(.caption).foregroundStyle(.secondary)
            if settings.choice == .claude {
                Text("Claude選択中: 入力はAnthropicへ送信されます")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom) {
                TextField("メッセージ", text: $input, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(turn.text).textSelection(.enabled)
                ReplyActionsView(text: turn.text)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
