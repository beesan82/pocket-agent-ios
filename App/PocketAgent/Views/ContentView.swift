import PocketAgentCore
import SwiftUI

/// Phase 0 home. Shows only facts the build itself can prove, plus the 0-5 screens.
struct ContentView: View {
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking

    var body: some View {
        NavigationStack {
            List {
                Section("Phase 0-5（実機で検証）") {
                    NavigationLink("1往復テスト") {
                        RoundTripView(settings: settings, credentials: credentials, availability: availability)
                    }
                    NavigationLink("設定") {
                        SettingsView(settings: settings, credentials: credentials, availability: availability)
                    }
                    LabeledContent("選択中のモデル", value: settings.choice.displayName)
                }
                Section("ビルド情報") {
                    LabeledContent("フェーズ", value: "Phase 0（技術スパイク）")
                    LabeledContent("AgentRunKit", value: SDKLinkCheck.agentRunKitLinked ? "リンク済み" : "未リンク")
                    LabeledContent("Claude API ホスト", value: SDKLinkCheck.anthropicHost)
                }
                Section("未実装") {
                    Text("チャット画面・履歴・LINE共有は未実装です。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pocket Agent")
        }
    }
}
