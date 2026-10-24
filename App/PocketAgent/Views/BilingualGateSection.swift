import PocketAgentCore
import SwiftUI
import Translation

/// Bilingual gate (stage A): Japanese and English recognizers on the same microphone audio, the
/// language decided per utterance, plus on-device translation timing. One screenshot carries the
/// result lines. Fixed texts only; underlying errors are never shown.
struct BilingualGateSection: View {
    let measurementLog: MeasurementLog

    private struct TranslationRow: Identifiable {
        let id = UUID()
        let direction: String
        let source: String
        let output: String
        let seconds: Double?
    }

    private static let japaneseSentences = [
        "納期は11月末まで延ばせますか？",
        "価格表は金曜日までに送ります。",
        "この件は次回の会議で決めましょう。",
    ]
    private static let englishSentences = [
        "That should be fine, but we need the updated price list first.",
        "Could you share the slides after the meeting?",
        "Let's move on to the next item on the agenda.",
    ]
    static let translationFailedText = "翻訳できませんでした。翻訳データを確認してください。"
    static let downloadFailedText = "翻訳データを入手できませんでした。通信環境を確認して再試行してください。"

    @State private var capture = SpeechCapture(locales: [Locale(identifier: "ja_JP"), SpeechCapture.english])
    @State private var arbiter = LanguageArbiter()
    @State private var decisions: [ArbiterDecision] = []
    @State private var expected: String?
    @State private var runTask: Task<Void, Never>?
    @State private var minAvailable: Int64?
    @State private var results: [String: BilingualRunStats] = [:]
    @State private var message: String?

    @State private var installed: [String: Bool] = [:]
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationRows: [TranslationRow] = []
    @State private var translationAverages: [String: Double] = [:]
    @State private var translating = false
    @State private var translationMessage: String?

    private var busy: Bool { expected != nil }

    var body: some View {
        Group {
            speechSection
            translationSection
        }
        .task {
            await capture.refreshAvailability()
            await refreshPairs()
            measurementLog.append("二言語 可否: \(capture.reason?.userMessage ?? "利用可能")")
        }
        .onDisappear { runTask?.cancel() }
    }

    // MARK: Speech

    private var speechSection: some View {
        Section("二言語（日英の自動判定）") {
            LabeledContent("可否", value: capture.reason?.userMessage ?? "利用可能")
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Button("権限を確認") {
                Task { await capture.requestPermissions() }
            }
            .disabled(busy)
            Button("音声データを入手（日・英）") { installAssets() }
                .disabled(busy)
            if busy {
                Button("停止", role: .destructive) { runTask?.cancel() }
            } else {
                Button("日本語で話す 30 秒") { startRun("ja") }
                    .disabled(capture.reason != nil)
                Button("英語で話す 30 秒") { startRun("en") }
                    .disabled(capture.reason != nil)
            }
            ForEach(["ja", "en"], id: \.self) { language in
                if let text = capture.laneVolatile[language], !text.isEmpty {
                    Text("\(language): \(text)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                decisionRow(decision)
            }
            ForEach(["ja", "en"], id: \.self) { language in
                if let stats = results[language] {
                    ForEach(stats.lines, id: \.self) { line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private func decisionRow(_ decision: ArbiterDecision) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !decision.accepted.isEmpty {
                HStack(alignment: .top) {
                    Text((decision.language ?? "?").uppercased()).font(.caption.bold())
                    Text(decision.accepted.map(\.text).joined(separator: " "))
                    Spacer()
                    Text(Self.score(decision.accepted)).font(.caption.monospacedDigit())
                }
            }
            ForEach(decision.rejected) { candidate in
                HStack(alignment: .top) {
                    Text(candidate.language.uppercased()).font(.caption)
                    Text(candidate.text).strikethrough()
                    Spacer()
                    Text(Self.score([candidate]) + " " + Self.label(decision.reason)).font(.caption.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private static func score(_ candidates: [LaneCandidate]) -> String {
        ConfidenceMath.weightedAverage(candidates.map { ($0.text.count, $0.confidence) })
            .map { String(format: "%.2f", $0) } ?? "—"
    }

    private static func label(_ reason: ArbiterDecision.Reason) -> String {
        switch reason {
        case .compared: "比較負け"
        case .single: "単独"
        case .noise: "雑音"
        case .late: "遅着"
        }
    }

    private func installAssets() {
        Task {
            measurementLog.append("二言語 音声データ導入開始")
            do {
                try await capture.installAssets()
                message = nil
                measurementLog.append("二言語 音声データ導入完了")
            } catch {
                message = SpeechCapture.installFailedText
                measurementLog.append("二言語 音声データ導入失敗")
            }
        }
    }

    private func startRun(_ language: String) {
        message = nil
        decisions = []
        arbiter = LanguageArbiter()
        minAvailable = nil
        expected = language
        runTask = Task {
            let events: AsyncStream<TranscriptEvent>
            do {
                events = try await capture.start()
            } catch {
                message = SpeechCapture.startFailedText
                measurementLog.append("二言語テスト開始失敗")
                expected = nil
                return
            }
            measurementLog.append("二言語テスト開始: \(language)")
            let consumer = Task {
                for await event in events { handle(event) }
            }
            let ticker = Task {
                while !Task.isCancelled {
                    sampleMemory()
                    decisions += arbiter.flush(now: capture.elapsed)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            // 停止 / leaving the screen cancels this task: the sleep ends early and the run still finishes.
            try? await Task.sleep(for: .seconds(30))
            ticker.cancel()
            await capture.stop()
            await consumer.value
            finishRun(language)
        }
    }

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case let .candidate(candidate):
            decisions += arbiter.submit(candidate)
        case let .failed(text):
            message = text
        case .volatile, .final, .interruptionEnded:
            break
        }
    }

    private func sampleMemory() {
        let available = DeviceProbes.availableMemoryBytes()
        if available > 0 { minAvailable = min(minAvailable ?? available, available) }
    }

    private func finishRun(_ language: String) {
        decisions += arbiter.drain()
        let stats = BilingualRunStats(
            expected: language, decisions: decisions,
            minAvailableMB: minAvailable.map { Int((Double($0) / 1_048_576).rounded()) })
        results[language] = stats
        stats.lines.forEach { measurementLog.append($0) }
        for decision in decisions {
            let shown = decision.accepted.map(\.text).joined(separator: " ")
            let dropped = decision.rejected.map { "\($0.language):\($0.text)" }.joined(separator: " / ")
            measurementLog.append(
                "  [\(decision.language ?? "-") \(Self.label(decision.reason))] \(shown) \(Self.score(decision.accepted))"
                    + (dropped.isEmpty ? "" : " ✕ \(dropped)"))
        }
        expected = nil
        runTask = nil
    }

    // MARK: Translation

    private var translationSection: some View {
        Section("翻訳（端末内）") {
            LabeledContent("日→英", value: installed["ja>en"] == true ? "導入済み" : "未導入")
            LabeledContent("英→日", value: installed["en>ja"] == true ? "導入済み" : "未導入")
            if let translationMessage {
                Text(translationMessage).font(.footnote).foregroundStyle(.red)
            }
            if installed["ja>en"] != true || installed["en>ja"] != true {
                Button("翻訳データを入手（日↔英）") { requestNextDownload() }
                    .disabled(translationConfig != nil)
            }
            Button("翻訳テスト") { runTranslationTest() }
                .disabled(translating || installed["ja>en"] != true || installed["en>ja"] != true)
            ForEach(translationRows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.source).font(.footnote).foregroundStyle(.secondary)
                    Text(row.output)
                    Text(row.direction + " " + (row.seconds.map { String(format: "%.1f 秒", $0) } ?? "失敗"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ForEach(translationAverageLines, id: \.self) { line in
                Text(line).font(.system(.footnote, design: .monospaced))
            }
        }
        .buttonStyle(.bordered)
        // The download consent sheet can only come from a view's session.
        .translationTask(translationConfig) { session in
            do {
                try await session.prepareTranslation()
                measurementLog.append("翻訳データ導入: \(Self.pairName(session))")
            } catch {
                translationMessage = Self.downloadFailedText
                measurementLog.append("翻訳データ導入失敗: \(Self.pairName(session))")
            }
            await refreshPairs()
            translationConfig = nil
        }
    }

    private var translationAverageLines: [String] {
        ["ja>en", "en>ja"].compactMap { key in
            translationAverages[key].map { "翻訳 \(key.replacingOccurrences(of: ">", with: "→")) 平均 " + String(format: "%.1f 秒", $0) }
        }
    }

    private static func pairName(_ session: TranslationSession) -> String {
        let source = session.sourceLanguage?.languageCode?.identifier ?? "?"
        let target = session.targetLanguage?.languageCode?.identifier ?? "?"
        return source + "→" + target
    }

    private func refreshPairs() async {
        installed["ja>en"] = await AppleTranslator.isInstalled(from: "ja", to: "en")
        installed["en>ja"] = await AppleTranslator.isInstalled(from: "en", to: "ja")
    }

    /// One pair per consent sheet; tap again for the other direction if it is still missing.
    private func requestNextDownload() {
        translationMessage = nil
        let (source, target) = installed["ja>en"] != true ? ("ja", "en") : ("en", "ja")
        translationConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
    }

    private func runTranslationTest() {
        translating = true
        translationMessage = nil
        translationRows = []
        translationAverages = [:]
        Task {
            let translator = AppleTranslator()
            let work = Self.japaneseSentences.map { ("ja", "en", $0) } + Self.englishSentences.map { ("en", "ja", $0) }
            var times: [String: [Double]] = [:]
            for (source, target, text) in work {
                let key = source + ">" + target
                let started = ContinuousClock.now
                do {
                    let output = try await translator.translate(text, from: source, to: target)
                    let elapsed = ContinuousClock.now - started
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    times[key, default: []].append(seconds)
                    translationRows.append(TranslationRow(
                        direction: key.replacingOccurrences(of: ">", with: "→"), source: text, output: output, seconds: seconds))
                } catch {
                    translationMessage = Self.translationFailedText
                    translationRows.append(TranslationRow(
                        direction: key.replacingOccurrences(of: ">", with: "→"), source: text, output: "—", seconds: nil))
                }
            }
            for (key, values) in times where !values.isEmpty {
                translationAverages[key] = values.reduce(0, +) / Double(values.count)
            }
            translationAverageLines.forEach { measurementLog.append($0) }
            translating = false
        }
    }
}
