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
    @Environment(PlamoModelStore.self) private var plamoStore
    @AppStorage(TranslationEngineChoice.storageKey) private var translationEngineRaw = TranslationEngineChoice.apple.rawValue
    @State private var pendingPlamoDownload: PendingPlamoDownload?
    @State private var confirmPlamoDelete = false
    @State private var plamoMessage: String?
    /// Read once, when the user taps download (as in ModelDownloadFlow).
    @State private var networkProbe = NetworkCostProbe()
    @State private var erasing = false

    private struct PendingPlamoDownload {
        let isExpensive: Bool
        let freeBytes: Int64
    }

    private var translationEngine: TranslationEngineChoice {
        TranslationEngineChoice(rawValue: translationEngineRaw) ?? .apple
    }

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
                Text("記録の要約と会議の要点は、Apple を選んでいて使える端末なら Apple、それ以外はダウンロードモデルで作ります（Claude は使いません）。ダウンロードモデルとAppleは端末内で処理し、外部へ送信しません。チャットで Claude を選んでいるときは、質問に関係する日誌・会議の内容も Anthropic へ送られます。")
            }

            translationSection

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

    private func translationChoiceRow(_ choice: TranslationEngineChoice) -> some View {
        Button {
            translationEngineRaw = choice.rawValue
        } label: {
            HStack {
                Text(choice.displayName)
                Spacer()
                if translationEngine == choice {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                        .accessibilityLabel("選択中")
                }
            }
        }
    }

    private var translationSection: some View {
        Section {
            translationChoiceRow(.apple)
            translationChoiceRow(.plamo)
            VStack(alignment: .leading, spacing: 6) {
                Text(plamoStore.model.displayName)
                Text("約 \(ModelDownloadFlow.megabytes(plamoStore.model.fileSizeBytes))・ライセンス: \(plamoStore.model.license)")
                    .font(.caption).foregroundStyle(.secondary)
                PlamoModelStatusView(status: plamoStore.status)
            }
            switch plamoStore.status {
            case .notDownloaded, .failed:
                Button("PLaMo モデルをダウンロード") { preparePlamoDownload() }
            case .downloading:
                Button("中断", role: .destructive) {
                    plamoStore.cancelDownload()
                    plamoMessage = nil
                }
            case .downloaded:
                Button("PLaMo モデルを削除", role: .destructive) { confirmPlamoDelete = true }
            }
            if let plamoMessage {
                Text(plamoMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("翻訳エンジン")
        } footer: {
            Text("二言語会議の翻訳に使います。どちらも端末内で処理し、外部へ送信しません。PLaMo の推論ランタイムは未統合のため、統合までは PLaMo を選んでも会議の翻訳は付きません（ADR-050）。")
        }
        .confirmationDialog(
            "ダウンロードしますか？",
            isPresented: Binding(
                get: { pendingPlamoDownload != nil }, set: { if !$0 { pendingPlamoDownload = nil } }),
            titleVisibility: .visible,
            presenting: pendingPlamoDownload
        ) { pending in
            Button("ダウンロード") { startPlamoDownload(pending) }
            Button("キャンセル", role: .cancel) {}
        } message: { pending in
            Text(plamoConfirmationText(pending))
        }
        .confirmationDialog(
            "モデルを削除しますか？", isPresented: $confirmPlamoDelete, titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) { deletePlamoModel() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(plamoStore.model.displayName) を端末から削除します。")
        }
    }

    private func preparePlamoDownload() {
        plamoMessage = nil
        // Unreadable free space is treated as zero: refuse rather than fill the disk.
        pendingPlamoDownload = PendingPlamoDownload(
            isExpensive: networkProbe.isExpensive, freeBytes: DeviceProbes.freeDiskBytes() ?? 0)
    }

    private func plamoConfirmationText(_ pending: PendingPlamoDownload) -> String {
        let model = plamoStore.model
        var lines = [
            model.displayName,
            "約 \(ModelDownloadFlow.megabytes(model.fileSizeBytes))",
            "ライセンス: \(model.license)",
            "通信が発生します",
        ]
        if pending.isExpensive { lines.append("モバイル通信中です。Wi-Fi の利用を推奨します") }
        return lines.joined(separator: "\n")
    }

    private func startPlamoDownload(_ pending: PendingPlamoDownload) {
        // The user has just confirmed (including the cellular warning), so no second confirmation.
        switch plamoStore.startDownload(freeBytes: pending.freeBytes, isExpensiveNetwork: false) {
        case .started:
            plamoMessage = nil
            measurementLog.append(
                "PLaMo モデルダウンロード開始: 約 \(ModelDownloadFlow.megabytes(plamoStore.model.fileSizeBytes))")
        case let .refusedDiskSpace(requiredBytes):
            plamoMessage = ModelUnavailableReason.insufficientDiskSpace(requiredBytes: requiredBytes).userMessage
        case .needsConfirmation:
            plamoMessage = nil
        case .busy:
            plamoMessage = "別のダウンロードが進行中です"
        }
    }

    private func deletePlamoModel() {
        plamoStore.delete()
        if plamoStore.isDeletionPending {
            plamoMessage = "ダウンロードの書き込み終了を待ってモデルを削除します。"
        } else if case .failed = plamoStore.status {
            plamoMessage = PlamoModelStore.deleteFailedText
            measurementLog.append("PLaMo モデル削除失敗")
        } else {
            plamoMessage = nil
            measurementLog.append("PLaMo モデル削除")
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
        plamoStore.refresh()
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
