import AgentRunKit
import PocketAgentCore
import SwiftUI
import UIKit

/// Phase 2-0 gate: measure the on-device MLX model and Japanese speech input on a real iPhone.
/// Fixed texts only; underlying errors are never shown.
struct MLXValidationView: View {
    let store: MLXModelStore
    let runtime: MLXRuntime
    let measurementLog: MeasurementLog
    let developer: DeveloperSettings
    let tokenStore: any CredentialStore

    /// 暫定: interim summary prompt for the gate measurement; the real prompt is decided later.
    static let interimSystemPrompt = """
        あなたは日記の要約アシスタントです。次の規則を守ってください。
        ・日本語で書く。
        ・1〜3文で要約する。
        ・固有名詞・日時・数字を落とさない。
        ・1行目は「見出し: 〜」の形式で、見出しは15文字以内にする。
        ・2行目以降に本文を書く。
        ・箇条書きは使わない。
        """

    private struct Sample: Identifiable {
        let id: String
        let label: String
        let text: String
    }

    private struct SummaryResult {
        let sampleID: String
        let output: SummaryOutput
        let seconds: Double
        let tokensPerSecond: Double?
    }

    private struct MemoryReading {
        var active: Int64?
        var available: Int64 = 0
    }

    private static let samples = [
        Sample(id: "short", label: "短文", text: MLXSampleTexts.short),
        Sample(id: "medium", label: "中文", text: MLXSampleTexts.medium),
        Sample(id: "long", label: "長文", text: MLXSampleTexts.long),
    ]

    @State private var speech = SpeechCapture()
    @State private var memory = MemoryReading()
    @State private var runningSampleID: String?
    @State private var summaryTask: Task<Void, Never>?
    @State private var summaryRun = 0
    @State private var result: SummaryResult?
    @State private var summaryMessage: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechMessage: String?
    @State private var copied = false
    @State private var confirmClear = false
    @State private var confirmUpload = false
    @State private var uploading = false
    @State private var hasToken = false
    @State private var uploadMessage: String?
    @State private var uploadSucceeded = false

    var body: some View {
        Form {
            logSection
            modelSection
            memorySection
            summarySection
            speechSection
        }
        .navigationTitle("MLX 検証")
        .task {
            store.refresh()
            refreshMemory()
            hasToken = (try? tokenStore.readAPIKey())?.isEmpty == false
            await speech.refreshAvailability()
            measurementLog.append("音声可否: \(speech.reason?.userMessage ?? "利用可能")")
        }
        .onChange(of: runtime.state) {
            refreshMemory()
            if runtime.state == .unloadedForMemory { measurementLog.append("メモリ警告によりモデルを解放") }
        }
        .onDisappear {
            summaryTask?.cancel()
            summaryTask = nil
            speechTask?.cancel()
            speechTask = nil
            Task { await speech.stop() }
        }
    }

    // MARK: Log

    private var logSection: some View {
        let text = { measurementLog.render(deviceInfo: DeviceInfo.summary, appVersion: DeviceInfo.appVersion) }
        return Section {
            LabeledContent("記録数", value: "\(measurementLog.entries.count) 件")
            HStack {
                Button("ログをコピー") {
                    UIPasteboard.general.string = text()
                    copied = true
                }
                ShareLink(item: text()) { Text("共有") }
                Button("クリア", role: .destructive) { confirmClear = true }
            }
            .buttonStyle(.bordered)
            if copied {
                Text("コピーしました").font(.footnote).foregroundStyle(.secondary)
            }
            if developer.isEnabled {
                Button("GitHub に送信") { confirmUpload = true }
                    .buttonStyle(.bordered)
                    .disabled(uploading || !hasToken)
                if !hasToken {
                    Text("設定の開発者モードでトークンを保存してください")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if uploading { ProgressView("送信中…") }
                if let uploadMessage {
                    Text(uploadMessage).font(.footnote)
                        .foregroundStyle(uploadSucceeded ? Color.secondary : Color.red)
                }
            }
            ForEach(measurementLog.entries.suffix(5)) { entry in
                Text(entry.line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        } header: {
            Text("測定ログ")
        } footer: {
            Text("コピーして、そのままチャットへ貼り付けてください。")
        }
        .confirmationDialog(
            "\(developer.repository) の非公開 Issue として送信します（\(measurementLog.entries.count) 行、音声テストの内容を含みます）",
            isPresented: $confirmUpload, titleVisibility: .visible
        ) {
            Button("送信") { Task { await uploadLog() } }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("ログを消去しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("クリア", role: .destructive) {
                measurementLog.clear()
                copied = false
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    /// Only reachable from the confirmation dialog's 送信 button.
    private func uploadLog() async {
        guard !uploading, developer.isEnabled,
              let token = try? tokenStore.readAPIKey(), !token.isEmpty
        else {
            hasToken = false
            return
        }
        uploading = true
        uploadMessage = nil
        let log = measurementLog.render(deviceInfo: DeviceInfo.summary, appVersion: DeviceInfo.appVersion)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let title = "測定ログ \(formatter.string(from: Date())) \(Self.deviceModelID)"
        let outcome = await MeasurementUploader().upload(
            log: log, title: title, repository: developer.repository, token: token)
        uploading = false
        switch outcome {
        case let .created(number):
            uploadSucceeded = true
            uploadMessage = "送信しました（Issue #\(number)）"
            measurementLog.append("ログを送信しました（Issue #\(number)）")
        case let .failed(failure):
            uploadSucceeded = false
            uploadMessage = failure.userMessage
        }
    }

    private static var deviceModelID: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Model

    private var modelSection: some View {
        let status = store.status(of: store.selected)
        return Section("モデル") {
            LabeledContent("選択中", value: store.selected.displayName)
            LabeledContent("ダウンロード", value: Self.statusText(status))
            LabeledContent("読み込み", value: Self.stateText(runtime.state))
            if let seconds = runtime.lastLoadSeconds {
                LabeledContent("読み込み時間", value: String(format: "%.1f 秒", seconds))
            }
            if let reason = MLXAvailability.reason(state: runtime.state, status: status) {
                Text(reason.userMessage).font(.footnote).foregroundStyle(.secondary)
            }
            if case let .failed(text) = runtime.state {
                Text(text).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                Button("読み込む") {
                    let model = store.selected
                    Task { await loadModel(model) }
                }
                .disabled(status != .downloaded || runtime.state == .loading || runtime.state == .loaded)
                Button("解放", role: .destructive) {
                    runtime.unload()
                    measurementLog.append("モデル解放（手動）")
                }
                    .disabled(runtime.state == .idle)
            }
            .buttonStyle(.bordered)
        }
    }

    private func loadModel(_ model: MLXModelInfo) async {
        refreshMemory()
        logMemory("読み込み前")
        measurementLog.append("モデル読み込み開始: \(model.displayName)")
        await runtime.load(model)
        refreshMemory()
        if runtime.state == .loaded {
            let seconds = runtime.lastLoadSeconds.map { String(format: "%.1f", $0) } ?? "不明"
            measurementLog.append("モデル読み込み完了: \(model.displayName) \(seconds) 秒")
        } else {
            measurementLog.append("モデル読み込み失敗: \(model.displayName)")
        }
        logMemory("読み込み後")
    }

    // MARK: Memory

    private func logMemory(_ label: String) {
        let active = memory.active.map(DeviceProbes.megabytes) ?? "取得不可"
        measurementLog.append(
            "メモリ（\(label)）: MLX active \(active) / 利用可能 \(DeviceProbes.megabytes(memory.available))")
    }

    private var memorySection: some View {
        Section {
            LabeledContent(
                "MLX activeMemory",
                value: memory.active.map(DeviceProbes.megabytes) ?? "取得不可")
            LabeledContent("利用可能メモリ", value: DeviceProbes.megabytes(memory.available))
            Button("更新") { refreshMemory() }
                .buttonStyle(.bordered)
        } header: {
            Text("メモリ")
        } footer: {
            Text("読み込み前後で「更新」を押して記録してください。シミュレータでは参考値になりません。")
        }
    }

    private func refreshMemory() {
        memory = MemoryReading(
            active: DeviceProbes.mlxActiveMemoryBytes(), available: DeviceProbes.availableMemoryBytes())
    }

    // MARK: Summary

    private var summarySection: some View {
        Section {
            ForEach(Self.samples) { sample in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(sample.label)（\(sample.text.count)字）").font(.headline)
                        Spacer()
                        if runningSampleID == sample.id {
                            Button("停止", role: .destructive) { cancelSummary() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("要約") { summarize(sample) }
                                .buttonStyle(.bordered)
                                .disabled(runtime.client == nil || runningSampleID != nil)
                        }
                    }
                    Text(sample.text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    if runningSampleID == sample.id {
                        ProgressView("生成中…")
                    }
                    if let result, result.sampleID == sample.id {
                        resultView(result)
                    }
                }
                .padding(.vertical, 2)
            }
            if let summaryMessage {
                Text(summaryMessage).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("要約テスト")
        } footer: {
            Text("プロンプトは暫定です。先にモデルを読み込んでください。")
        }
    }

    @ViewBuilder
    private func resultView(_ result: SummaryResult) -> some View {
        let rate = result.tokensPerSecond.map { String(format: "%.1f tokens/s", $0) } ?? "tokens/s: 不明"
        VStack(alignment: .leading, spacing: 4) {
            if let title = result.output.title {
                Text("見出し: \(title)").font(.subheadline.bold())
            }
            Text(result.output.body).textSelection(.enabled)
            Text(String(format: "所要 %.1f 秒", result.seconds) + "・" + rate)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryRun += 1  // a late result of the cancelled run is dropped
        if let id = runningSampleID, let sample = Self.samples.first(where: { $0.id == id }) {
            measurementLog.append("要約を停止: \(sample.label)")
        }
        runningSampleID = nil
    }

    private func summarize(_ sample: Sample) {
        guard let client = runtime.client, runningSampleID == nil else { return }
        summaryRun += 1
        let run = summaryRun
        runningSampleID = sample.id
        summaryMessage = nil
        result = nil
        let context = RequestContext(extraFields: [
            "max_tokens": .int(512),
            "temperature": .double(0.7),
            "top_p": .double(0.8),
            "repetition_penalty": .double(1.1),
        ])
        let messages: [ChatMessage] = [.system(Self.interimSystemPrompt), .user(sample.text)]
        // Started from a view method, so the task runs on the main actor.
        summaryTask = Task {
            let start = ContinuousClock.now
            let outcome: Result<AssistantMessage, any Error>
            do {
                outcome = .success(try await client.generate(
                    messages: messages, tools: [], responseFormat: nil, requestContext: context))
            } catch {
                outcome = .failure(error)
            }
            guard run == summaryRun, !Task.isCancelled else { return }
            let parts = (ContinuousClock.now - start).components
            let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            runningSampleID = nil
            summaryTask = nil
            switch outcome {
            case let .success(message):
                let tokens = message.tokenUsage?.output
                let rate = tokens.flatMap { elapsed > 0 && $0 > 0 ? Double($0) / elapsed : nil }
                let output = SummaryParser.parse(message.content)
                result = SummaryResult(
                    sampleID: sample.id, output: output, seconds: elapsed, tokensPerSecond: rate)
                let tokenText = tokens.map { "\($0)" } ?? "不明"
                let rateText = rate.map { String(format: "%.1f", $0) } ?? "不明"
                measurementLog.append(
                    "要約（\(sample.label)・入力\(sample.text.count)字）: 所要 "
                        + String(format: "%.1f", elapsed)
                        + " 秒 / 出力 \(tokenText) tokens / \(rateText) tokens/s / 見出し: \(output.title ?? "なし")"
                        + " / 本文先頭: \(String(output.body.prefix(80)))")
                measurementLog.append("  > \(output.body)")
            case .failure:
                summaryMessage = "要約を生成できませんでした。モデルを読み込み直してから、もう一度お試しください。"
                measurementLog.append("要約失敗: \(sample.label)")
            }
            refreshMemory()
            logMemory("要約後・\(sample.label)")
        }
    }

    // MARK: Speech

    private var speechBusy: Bool {
        switch speech.state {
        case .preparing, .recording, .finishing: true
        case .idle, .failed: false
        }
    }

    private var speechSection: some View {
        Section("音声") {
            LabeledContent("可否", value: speech.reason?.userMessage ?? "利用可能")
            if case let .failed(text) = speech.state {
                Text(text).font(.footnote).foregroundStyle(.red)
            }
            if let speechMessage {
                Text(speechMessage).font(.footnote).foregroundStyle(.red)
            }
            Button("権限を確認") {
                Task {
                    await speech.requestPermissions()
                    await speech.refreshAvailability()
                    measurementLog.append("音声権限確認: \(speech.reason?.userMessage ?? "利用可能")")
                }
            }
            .disabled(speechBusy)
            Button("アセットを導入") {
                Task {
                    let start = ContinuousClock.now
                    measurementLog.append("音声アセット導入開始")
                    do {
                        try await speech.installAssets()
                        speechMessage = nil
                        measurementLog.append(
                            "音声アセット導入完了: " + String(format: "%.1f", Self.seconds(ContinuousClock.now - start)) + " 秒")
                    } catch {
                        speechMessage = SpeechCapture.installFailedText
                        measurementLog.append("音声アセット導入失敗")
                    }
                }
            }
            .disabled(speechBusy)
            if speechBusy {
                Button("停止", role: .destructive) { stopSpeechTest() }
            } else {
                Button("30秒テスト") { startSpeechTest() }
            }
            if !speech.volatileText.isEmpty {
                Text(speech.volatileText).foregroundStyle(.secondary)
            }
            if !speech.finalText.isEmpty {
                Text(speech.finalText).textSelection(.enabled)
            }
        }
        .buttonStyle(.bordered)
    }

    private func startSpeechTest() {
        speechMessage = nil
        speechTask?.cancel()
        speechTask = Task {
            do {
                try await speech.start()
                measurementLog.append("音声30秒テスト開始")
            } catch {
                speechMessage = SpeechCapture.startFailedText
                measurementLog.append("音声30秒テスト開始失敗")
                speechTask = nil
                return
            }
            // Auto-stop; cancelling the task (停止 / leaving the screen) ends the wait early.
            try? await Task.sleep(for: .seconds(30))
            // Cancelled: the 停止 / disappear path already stops, and a newer test may be running.
            guard !Task.isCancelled else { return }
            await speech.stop()
            speechTask = nil
            logSpeechResult()
        }
    }

    private func stopSpeechTest() {
        speechTask?.cancel()
        speechTask = nil
        Task {
            await speech.stop()
            logSpeechResult()
        }
    }

    private func logSpeechResult() {
        measurementLog.append("音声30秒テスト結果: 確定テキスト \(speech.finalText.count) 字")
        measurementLog.append("  > \(speech.finalText)")
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: Text

    private static func statusText(_ status: MLXModelStore.Status) -> String {
        switch status {
        case .notDownloaded: "未ダウンロード"
        case let .downloading(fraction): "ダウンロード中 \(Int(fraction * 100))%"
        case .downloaded: "ダウンロード済み"
        case let .failed(text): text
        }
    }

    private static func stateText(_ state: MLXRuntime.State) -> String {
        switch state {
        case .idle: "未読み込み"
        case .loading: "読み込み中…"
        case .loaded: "読み込み済み"
        case .unloadedForMemory: "メモリ不足で解放"
        case .failed: "読み込み失敗"
        }
    }
}
