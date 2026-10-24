import PocketAgentCore
import SwiftData
import SwiftUI

/// FR-02 / FR-03: model choice, Claude API key (Keychain only), Apple on-device availability.
struct SettingsView: View {
    @Bindable var settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking
    let mlxStore: MLXModelStore
    let mlxRuntime: MLXRuntime
    let measurementLog: MeasurementLog
    @Bindable var developer: DeveloperSettings
    let tokenStore: any CredentialStore
    let journal: any JournalStore

    @Environment(\.modelContext) private var modelContext
    @State private var confirmErase = false
    @State private var eraseStatus: String?
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var keyStatus: String?
    @State private var tokenInput = ""
    @State private var hasToken = false
    @State private var tokenStatus: String?
    @State private var appleReason: ModelUnavailableReason?
    @Environment(ModelDownloadFlow.self) private var downloadFlow
    @Environment(JournalDraftStore.self) private var drafts
    @State private var erasing = false

    var body: some View {
        Form {
            Section {
                choiceRow(.claude, title: "Claude")
                SecureField("APIキーを貼り付け", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存") { saveKey() }
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("削除", role: .destructive) { deleteKey() }
                    .disabled(!hasKey)
                LabeledContent("APIキーの状態", value: hasKey ? "保存済み" : "未保存")
                if let keyStatus {
                    Text(keyStatus).font(.footnote).foregroundStyle(.secondary)
                }
                TextField("Claude モデルID", text: $settings.claudeModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("クラウド")
            } footer: {
                Text("キーはこの端末のKeychainにのみ保存され、画面には再表示されません。Claude選択中は、入力と会話の一部がAnthropicへ送信されます。")
            }

            Section {
                choiceRow(.appleLocal, title: "Apple（Apple Intelligence）")
                    .disabled(appleReason != nil)
                if let appleReason {
                    Text("使えません: \(appleReason.userMessage)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("ダウンロードモデル").font(.subheadline).foregroundStyle(.secondary)
                ForEach(MLXModelRegistry.all) { model in
                    DownloadModelRow(
                        model: model, flow: downloadFlow,
                        isChosen: settings.choice == .mlxLocal && mlxStore.selected == model
                    ) {
                        mlxStore.selected = model
                        settings.choice = .mlxLocal
                    }
                }
                if let message = downloadFlow.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("ローカル（端末内）")
            } footer: {
                Text("日誌タブの要約と会議の要点は、Apple を選んでいて使える端末なら Apple、それ以外はダウンロードモデルで作ります（Claude は使いません）。ダウンロードモデルとAppleは端末内で処理し、外部へ送信しません。チャットで Claude を選んでいるときは、質問に関係する日誌・会議の内容も Anthropic へ送られます。")
            }

            Section("検証") {
                NavigationLink("1往復テスト（実機検証用）") {
                    RoundTripView(settings: settings, credentials: credentials, availability: availability)
                }
                NavigationLink("モデル管理（詳細）") {
                    MLXModelsView(store: mlxStore, measurementLog: measurementLog)
                }
                NavigationLink("MLX 検証（実機ゲート）") {
                    MLXValidationView(
                        store: mlxStore, runtime: mlxRuntime, measurementLog: measurementLog,
                        developer: developer, tokenStore: tokenStore)
                }
            }

            developerSection

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
        .disabled(erasing)
        .confirmationDialog(
            "会話・日誌・下書き・測定ログ・APIキー・GitHub トークンをすべて削除します", isPresented: $confirmErase, titleVisibility: .visible
        ) {
            Button("全データ削除", role: .destructive) { Task { await eraseAll() } }
            Button("キャンセル", role: .cancel) {}
        }
        .task { refresh() }
    }

    private func choiceRow(_ choice: ModelChoice, title: String) -> some View {
        Button {
            settings.choice = choice
        } label: {
            HStack {
                Text(title)
                Spacer()
                if settings.choice == choice {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                        .accessibilityLabel("選択中")
                }
            }
        }
    }

    private var developerSection: some View {
        Section {
            Toggle("開発者モード", isOn: $developer.isEnabled)
                .onChange(of: developer.isEnabled) { _, enabled in
                    if !enabled { tokenInput = "" }
                }
            if developer.isEnabled {
                SecureField("GitHub トークン", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存") { saveToken() }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("削除", role: .destructive) { deleteToken() }
                    .disabled(!hasToken)
                LabeledContent("トークン", value: hasToken ? "保存済み" : "未保存")
                if let tokenStatus {
                    Text(tokenStatus).font(.footnote).foregroundStyle(.secondary)
                }
                TextField("送信先リポジトリ", text: $developer.repository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !DeveloperSettings.isValidRepository(developer.repository) {
                    Text(UploadFailure.invalidRepository.userMessage)
                        .font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("開発者")
        } footer: {
            if developer.isEnabled {
                Text("測定ログを、あなたが送信ボタンを押したときだけ、この非公開リポジトリの Issue として送ります。ログには音声テストで話した内容が含まれます。トークンは端末の Keychain にだけ保存されます。")
            }
        }
    }

    private func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try tokenStore.saveAPIKey(token)
            tokenInput = ""
            hasToken = true
            tokenStatus = "保存しました"
        } catch {
            tokenStatus = "保存に失敗しました"
        }
    }

    private func deleteToken() {
        do {
            try tokenStore.deleteAPIKey()
            hasToken = false
            tokenStatus = "削除しました"
        } catch {
            tokenStatus = "削除に失敗しました"
        }
    }

    private func eraseAll() async {
        guard !erasing else { return }
        erasing = true
        defer { erasing = false }
        do {
            try await DataReset.eraseAll(
                context: modelContext,
                journal: journal,
                credentials: credentials, githubToken: tokenStore,
                measurementLog: measurementLog, drafts: drafts)
            developer.isEnabled = false
            tokenInput = ""
            eraseStatus = "すべてのデータを削除しました"
        } catch {
            eraseStatus = "削除を完了できませんでした。もう一度お試しください"
        }
        keyInput = ""
        tokenInput = ""
        refresh()
    }

    private func refresh() {
        // If Apple local is already selected but unavailable, the choice is kept as is:
        // switching to Claude silently would send the conversation to the cloud (AT-03).
        mlxStore.refresh()
        appleReason = availability.appleLocalUnavailableReason()
        do {
            hasKey = try credentials.readAPIKey()?.isEmpty == false
        } catch {
            hasKey = false
            keyStatus = "キーの読み出しに失敗しました"
        }
        hasToken = (try? tokenStore.readAPIKey())?.isEmpty == false
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try credentials.saveAPIKey(key)
            keyInput = ""
            hasKey = true
            keyStatus = "保存しました"
        } catch {
            keyStatus = "保存に失敗しました"
        }
    }

    private func deleteKey() {
        do {
            try credentials.deleteAPIKey()
            hasKey = false
            keyStatus = "削除しました"
        } catch {
            keyStatus = "削除に失敗しました"
        }
    }
}
