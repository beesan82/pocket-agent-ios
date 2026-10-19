import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// Asks the user to approve one tool call. Any dismissal without a button press denies.
struct ApprovalSheet: View {
    let request: PendingApprovalRequest
    let broker: ApprovalBroker


    static func toolLabel(_ name: String) -> String {
        switch name {
        case NoteToolName.save: "メモを保存"
        case NoteToolName.edit: "メモを編集"
        case NoteToolName.list: "メモ一覧"
        case NoteToolName.search: "メモ検索"
        case NoteToolName.delete: "メモを削除"
        default: name
        }
    }

    static func riskText(_ risk: ToolRisk) -> String {
        switch risk {
        case .readOnly: "データを読み取るだけです。"
        case .appInternalWrite: "このアプリ内にデータを書き込みます。"
        case .appInternalDelete: "このアプリ内のデータを削除します。毎回確認します。"
        case .externalSideEffect: "アプリの外に影響します。毎回確認します。"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("操作") {
                    Text(Self.toolLabel(request.approval.toolName)).font(.headline)
                }
                Section("内容") {
                    Text(request.summary).textSelection(.enabled)
                }
                Section("リスク") {
                    Text(Self.riskText(request.approval.risk))
                }
                Section {
                    Button("今回だけ許可") { answer(.approveOnce) }
                    if request.approval.risk.allowsSessionWideApproval {
                        Button("この会話では許可") { answer(.approveForSession) }
                    }
                    Button("拒否", role: .destructive) { answer(.deny(reason: nil)) }
                }
            }
            .navigationTitle("確認")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        // Any dismissal denies; a no-op once this request was answered.
        .onDisappear { broker.deny(id: request.id) }
    }

    private func answer(_ decision: UserApprovalDecision) {
        broker.answer(decision)
    }
}
