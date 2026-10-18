import PocketAgentCore
import SwiftData
import SwiftUI

/// The user's notes. Deleting here is the user's own action, so there is no approval dialog.
struct NotesView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var notes: [Note] = []
    @State private var errorText: String?

    private var store: JournalNoteStore {
        JournalNoteStore(journal: SwiftDataJournalStore(modelContainer: modelContext.container))
    }

    var body: some View {
        List {
            if notes.isEmpty {
                Text("メモはまだありません。").foregroundStyle(.secondary)
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.text)
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: delete)
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .navigationTitle("メモ")
        .task { await refresh() }
    }

    private func refresh() async {
        do {
            notes = try await store.all()
        } catch {
            errorText = "メモを読み込めませんでした"
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { notes[$0].id }
        let store = store
        Task {
            do {
                for id in ids { _ = try await store.delete(id: id) }
                errorText = nil
            } catch {
                errorText = "メモを削除できませんでした"
            }
            await refresh()
        }
    }
}
