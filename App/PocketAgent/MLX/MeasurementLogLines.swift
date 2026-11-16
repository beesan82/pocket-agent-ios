import Foundation
import PocketAgentCore

/// The measurement-log lines that are built from spoken or generated text.
/// They carry counts and timings only, never the text itself (ADR-026, ADR-053):
/// the log can leave the device (copy, share sheet, GitHub Issue).
enum MeasurementLogLines {
    /// 30-second voice test: how much was recognized, not what.
    static func speechTestResult(finalText: String, termCorrectionCount: Int) -> String {
        "音声30秒テスト結果: 確定テキスト \(finalText.count) 字 / 用語補正 \(termCorrectionCount) 件"
    }

    /// Summary test: timing, token counts and the lengths of the model's title and body.
    static func summaryResult(
        label: String, inputChars: Int, seconds: Double, outputTokens: Int?, tokensPerSecond: Double?,
        title: String?, body: String
    ) -> String {
        let tokenText = outputTokens.map { "\($0)" } ?? "不明"
        let rateText = tokensPerSecond.map { String(format: "%.1f", $0) } ?? "不明"
        let titleText = title.map { "\($0.count) 字" } ?? "なし"
        return "要約（\(label)・入力\(inputChars)字）: 所要 "
            + String(format: "%.1f", seconds)
            + " 秒 / 出力 \(tokenText) tokens / \(rateText) tokens/s / 見出し \(titleText) / 本文 \(body.count) 字"
    }

    /// One language decision of the bilingual gate: language, reason, score and lengths.
    static func bilingualDecision(
        language: String?, reasonLabel: String, score: String,
        accepted: [LaneCandidate], rejected: [LaneCandidate]
    ) -> String {
        let shown = accepted.reduce(0) { $0 + $1.text.count }
        let dropped = rejected.map { "\($0.language):\($0.text.count) 字" }.joined(separator: " / ")
        return "  判定[\(language ?? "-") \(reasonLabel)] \(shown) 字 \(score)"
            + (dropped.isEmpty ? "" : " ✕ \(dropped)")
    }

    /// Lines written by builds before ADR-053, which carried recognized text or summary bodies.
    /// They are dropped when the log is loaded, so an old log never leaves the device with them.
    static func isLegacyContentLine(_ line: String) -> Bool {
        line.hasPrefix("  > ") || line.hasPrefix("  [") || line.contains(" / 本文先頭: ")
    }
}
