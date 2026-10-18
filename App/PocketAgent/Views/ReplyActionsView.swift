import PocketAgentCore
import SwiftUI
import UIKit

/// Edit / copy / share-to-LINE for one assistant reply.
/// The edited text lives only in this view's state: it is not persisted and history is untouched.
struct ReplyActionsView: View {
    let text: String

    @Environment(\.openURL) private var openURL
    @State private var edited: String?
    @State private var showEditor = false
    @State private var flow = ShareFlow()
    // Presentation only: `flow` is changed solely by the dialog's button actions, so SwiftUI
    // resetting this flag before running "LINEを開く" can never cancel the share.
    @State private var showDialog = false

    private var currentText: String { edited ?? text }

    private var confirmingText: String? {
        if case let .confirming(text) = flow.state { text } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let edited {
                Text("編集した文面（この表示のみ・保存されません）")
                    .font(.caption).foregroundStyle(.secondary)
                Text(edited).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                Button("編集") { showEditor = true }
                Button("コピー") { UIPasteboard.general.string = currentText }
                Button("LINEで共有") {
                    flow.request(currentText)
                    showDialog = confirmingText != nil
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            if let message = ShareFlow.statusMessage(for: flow.state) {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showEditor) {
            ReplyEditSheet(initial: currentText) { edited = $0 }
        }
        .confirmationDialog(
            "LINEで共有", isPresented: $showDialog, titleVisibility: .visible, presenting: confirmingText
        ) { _ in
            Button("LINEを開く") { openLine() }
            // Also runs when the dialog is dismissed by tapping outside.
            Button("キャンセル", role: .cancel) { flow.cancel() }
        } message: { preview in
            Text("\(String(preview.prefix(200)))\n\nLINEの送信先選択画面を開きます。送信はLINEであなたが行います")
        }
    }

    private func openLine() {
        guard let url = flow.confirm() else { return }
        openURL(url) { accepted in
            flow.didOpen(accepted)
        }
    }
}

private struct ReplyEditSheet: View {
    let initial: String
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .padding()
                .navigationTitle("編集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            onDone(draft)
                            dismiss()
                        }
                    }
                }
        }
        .onAppear { draft = initial }
    }
}
