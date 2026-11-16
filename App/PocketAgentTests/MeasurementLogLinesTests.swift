import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

/// ADR-026 / ADR-053: the measurement log carries counts and timings, never spoken or generated text.
@MainActor
struct MeasurementLogLinesTests {
    private static let spoken = "来週の役員会で人事異動を発表する予定です"
    private static let summaryTitle = "役員会の予定"
    private static let summaryBody = "来週の役員会で人事異動が発表される。関係者には事前に伝える。"

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "measurement-log-lines-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "measurement-log.txt")
    }

    @Test func speechTestLineHasCountsButNotTheSpokenText() {
        let line = MeasurementLogLines.speechTestResult(finalText: Self.spoken, termCorrectionCount: 2)

        #expect(line == "音声30秒テスト結果: 確定テキスト \(Self.spoken.count) 字 / 用語補正 2 件")
        #expect(!line.contains(Self.spoken))
        #expect(!line.contains("役員会"))
        #expect(!line.contains("\n"))
    }

    @Test func summaryLineHasTimingAndLengthsButNotTheSummary() {
        let line = MeasurementLogLines.summaryResult(
            label: "短文", inputChars: 66, seconds: 3.04, outputTokens: 54, tokensPerSecond: 17.86,
            title: Self.summaryTitle, body: Self.summaryBody)

        #expect(line == "要約（短文・入力66字）: 所要 3.0 秒 / 出力 54 tokens / 17.9 tokens/s"
            + " / 見出し \(Self.summaryTitle.count) 字 / 本文 \(Self.summaryBody.count) 字")
        #expect(!line.contains(Self.summaryTitle))
        #expect(!line.contains(Self.summaryBody))
        #expect(!line.contains("人事異動"))
        #expect(!line.contains("\n"))
    }

    @Test func summaryLineReportsMissingValuesWithoutText() {
        let line = MeasurementLogLines.summaryResult(
            label: "長文", inputChars: 908, seconds: 12, outputTokens: nil, tokensPerSecond: nil,
            title: nil, body: Self.summaryBody)

        #expect(line == "要約（長文・入力908字）: 所要 12.0 秒 / 出力 不明 tokens / 不明 tokens/s"
            + " / 見出し なし / 本文 \(Self.summaryBody.count) 字")
    }

    @Test func bilingualDecisionLineHasLengthsButNotTheUtterances() {
        func candidate(_ language: String, _ text: String) -> LaneCandidate {
            LaneCandidate(language: language, text: text, confidence: 0.8, start: 0, end: 1, arrivedAt: 1)
        }
        let line = MeasurementLogLines.bilingualDecision(
            language: "ja", reasonLabel: "比較負け", score: "0.80",
            accepted: [candidate("ja", Self.spoken)], rejected: [candidate("en", "confidential plan")])

        #expect(line == "  判定[ja 比較負け] \(Self.spoken.count) 字 0.80 ✕ en:17 字")
        #expect(!line.contains(Self.spoken))
        #expect(!line.contains("confidential"))
        #expect(!MeasurementLogLines.isLegacyContentLine(line))
    }

    @Test func legacyContentLinesAreRecognized() {
        #expect(MeasurementLogLines.isLegacyContentLine("  > \(Self.spoken)"))
        #expect(MeasurementLogLines.isLegacyContentLine("  [ja 単独] \(Self.spoken) 0.80"))
        #expect(MeasurementLogLines.isLegacyContentLine(
            "要約（短文・入力66字）: 所要 3.0 秒 / 出力 54 tokens / 17.9 tokens/s / 見出し: 予定 / 本文先頭: 来週の"))
        #expect(!MeasurementLogLines.isLegacyContentLine(
            MeasurementLogLines.speechTestResult(finalText: Self.spoken, termCorrectionCount: 0)))
        #expect(!MeasurementLogLines.isLegacyContentLine(MeasurementLogLines.summaryResult(
            label: "短文", inputChars: 66, seconds: 3, outputTokens: 54, tokensPerSecond: 18,
            title: Self.summaryTitle, body: Self.summaryBody)))
        #expect(!MeasurementLogLines.isLegacyContentLine("モデル読み込み完了: Qwen2.5 1.5B 0.6 秒"))
    }

    /// A log written by an earlier build still holds what was said: loading drops those lines,
    /// in memory and on disk, and keeps the measurements.
    @Test func loadingDropsLegacyContentLinesFromMemoryAndDisk() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = MeasurementLog(fileURL: url)
        old.append("音声30秒テスト結果: 確定テキスト 20 字 / 用語補正 0 件")
        old.append("  > \(Self.spoken)")
        old.append("  [ja 単独] \(Self.spoken) 0.80")
        old.append("メモリ（読み込み後）: MLX active 831 MB / 利用可能 2066 MB")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("役員会"))

        let reloaded = MeasurementLog(fileURL: url)

        #expect(reloaded.entries.map(\.line) == [
            "音声30秒テスト結果: 確定テキスト 20 字 / 用語補正 0 件",
            "メモリ（読み込み後）: MLX active 831 MB / 利用可能 2066 MB",
        ])
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("役員会"))
        let rendered = reloaded.render(deviceInfo: "iPhone15,4 / iOS 27.0", appVersion: "0.0.1 (32)")
        #expect(!rendered.contains("役員会"))
    }
}
