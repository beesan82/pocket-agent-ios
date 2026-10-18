import PocketAgentCore
import SwiftData
import SwiftUI

/// FR-02 / FR-03: model choice, Claude API key (Keychain only), Apple on-device availability.
struct SettingsView: View {
    @Bindable var settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking

    @Environment(\.modelContext) private var modelContext
    @State private var confirmErase = false
    @State private var eraseStatus: String?
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var keyStatus: String?
    @State private var appleReason: ModelUnavailableReason?

    var body: some View {
        Form {
            Section {
                ForEach(ModelChoice.allCases, id: \.self) { choice in
                    Button {
                        settings.choice = choice
                    } label: {
                        HStack {
                            Text(choice.displayName)
                            Spacer()
                            if settings.choice == choice {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(choice == .appleLocal && appleReason != nil)
                }
            } header: {
                Text("使用するモデル")
            } footer: {
                if let appleReason {
                    Text("Appleローカルは使えません: \(appleReason.userMessage)")
                } else {
                    Text("Appleローカルは端末内で推論し、会話を外部へ送信しません。")
                }
            }

            Section {
                SecureField("APIキーを貼り付け", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("削除", role: .destructive) { deleteKey() }
                    .disabled(!hasKey)
                LabeledContent("状態", value: hasKey ? "保存済み" : "未保存")
                if let keyStatus {
                    Text(keyStatus).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Claude APIキー")
            } footer: {
                Text("キーはこの端末のKeychainにのみ保存され、画面には再表示されません。")
            }

            Section("Claude モデルID") {
                TextField("モデルID", text: $settings.claudeModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("検証") {
                NavigationLink("1往復テスト（実機検証用）") {
                    RoundTripView(settings: settings, credentials: credentials, availability: availability)
                }
            }

            Section("データ") {
                Button("全データ削除", role: .destructive) { confirmErase = true }
                if let eraseStatus {
                    Text(eraseStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("ビルド情報") {
                LabeledContent("AgentRunKit", value: SDKLinkCheck.agentRunKitLinked ? "リンク済み" : "未リンク")
                LabeledContent("Claude API ホスト", value: SDKLinkCheck.anthropicHost)
            }
        }
        .navigationTitle("設定")
        .confirmationDialog(
            "会話・メモ・APIキーをすべて削除します", isPresented: $confirmErase, titleVisibility: .visible
        ) {
            Button("全データ削除", role: .destructive) { Task { await eraseAll() } }
            Button("キャンセル", role: .cancel) {}
        }
        .task { refresh() }
    }

    private func eraseAll() async {
        do {
            try await DataReset.eraseAll(
                context: modelContext,
                notes: SwiftDataNoteStore(modelContainer: modelContext.container),
                credentials: credentials)
            eraseStatus = "すべてのデータを削除しました"
        } catch {
            eraseStatus = "削除を完了できませんでした。もう一度お試しください"
        }
        refresh()
    }

    private func refresh() {
        // If Apple local is already selected but unavailable, the choice is kept as is:
        // switching to Claude silently would send the conversation to the cloud (AT-03).
        appleReason = availability.appleLocalUnavailableReason()
        do {
            hasKey = try credentials.readAPIKey()?.isEmpty == false
        } catch {
            hasKey = false
            keyStatus = "キーの読み出しに失敗しました（\(error)）"
        }
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try credentials.saveAPIKey(key)
            keyInput = ""
            hasKey = true
            keyStatus = "保存しました"
        } catch {
            keyStatus = "保存に失敗しました（\(error)）"
        }
    }

    private func deleteKey() {
        do {
            try credentials.deleteAPIKey()
            hasKey = false
            keyStatus = "削除しました"
        } catch {
            keyStatus = "削除に失敗しました（\(error)）"
        }
    }
}
