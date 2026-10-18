import PocketAgentCore
import SwiftData
import SwiftUI

struct ConversationListView: View {
    @Binding var path: NavigationPath
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConversationRecord.updatedAt, order: .reverse) private var conversations: [ConversationRecord]
    @State private var errorText: String?

    var body: some View {
        List {
            if conversations.isEmpty {
                Text("会話はまだありません。「新しい会話」から始めましょう。")
                    .foregroundStyle(.secondary)
            }
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title).font(.headline).lineLimit(2)
                        HStack {
                            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(ModelChoice(rawValue: conversation.modelChoiceRaw)?.displayName ?? "-")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Pocket Agent")
        .navigationDestination(for: ConversationRecord.self) { conversation in
            ChatView(
                conversation: conversation, settings: settings,
                credentials: credentials, availability: availability)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    NotesView()
                } label: {
                    Text("メモ")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(
                        settings: settings, credentials: credentials, availability: availability,
                        mlxStore: mlxStore, mlxRuntime: mlxRuntime, measurementLog: measurementLog)
                } label: {
                    Text("設定")
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("新しい会話", systemImage: "square.and.pencil") { create() }
            }
        }
        .alert("操作できませんでした", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func create() {
        do {
            let record = try ConversationRepository(context: modelContext).create(choice: settings.choice)
            path.append(record)
        } catch {
            errorText = "会話を作成できませんでした"
        }
    }

    private func delete(at offsets: IndexSet) {
        let repository = ConversationRepository(context: modelContext)
        let targets = offsets.map { conversations[$0] }
        do {
            for conversation in targets { try repository.delete(conversation) }
        } catch {
            errorText = "会話を削除できませんでした"
        }
    }
}
