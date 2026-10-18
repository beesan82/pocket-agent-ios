import SwiftUI

/// Phase 0 placeholder. Shows only facts the build itself can prove.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("ビルド情報") {
                    LabeledContent("フェーズ", value: "Phase 0（技術スパイク）")
                    LabeledContent("AgentRunKit", value: SDKLinkCheck.agentRunKitLinked ? "リンク済み" : "未リンク")
                    LabeledContent("Claude API ホスト", value: SDKLinkCheck.anthropicHost)
                }
                Section("未実装") {
                    Text("チャット・モデル切替・LINE共有は未実装です。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pocket Agent")
        }
    }
}

#Preview {
    ContentView()
}
