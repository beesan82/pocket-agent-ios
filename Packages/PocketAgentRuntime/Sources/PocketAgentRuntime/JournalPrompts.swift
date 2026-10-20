import Foundation
import PocketAgentCore

/// Prompts for the on-device journal features (summary, search terms, answer).
public enum JournalPrompts {
    public static let summarySystem = """
    あなたは日誌の要約係です。ユーザーの文章を日本語で要約してください。
    - 箇条書きにせず、1〜3 文にまとめる。
    - 固有名詞・日時・数字は省かない。
    - 出力形式: 1 行目は「見出し: 」に続けて 15 文字以内の見出し、2 行目以降に要約本文。
    - それ以外の説明や前置きは書かない。
    """

    public static func summaryUser(text: String, recordedAt: Date, calendar: Calendar = .current) -> String {
        "次の文章を要約してください。\n\n\(text)"
    }

    public static let termsSystem = """
    あなたは日誌検索の検索語を選ぶ係です。質問から日誌を探すための短い検索語を最大 5 個選んでください。
    - 検索語は質問に含まれる単語か短い句にする。
    - 出力は JSON 配列だけ（例: ["歯医者", "予約"]）。説明や前置きは書かない。
    """

    public static func termsUser(question: String) -> String {
        "質問: \(question)"
    }

    public static let answerSystem = """
    あなたは日誌の内容に答える係です。与えられた日誌だけを根拠に、日本語で答えてください。
    - 日誌に答えが書かれていなければ「日誌に記録がありません」と答える。
    - 日誌にないことを推測で補わない。
    - 3〜5 文で簡潔に答える。
    """

    public static func answerUser(
        question: String, packed: [PackedEntry], usedRecentFallback: Bool, now: Date, calendar: Calendar = .current
    ) -> String {
        let formatter = dayFormatter(calendar)
        var lines: [String] = []
        if usedRecentFallback {
            lines.append("質問に合う日誌が見つからなかったため、直近の日誌を渡します。回答は「直近の日誌から：」で始めてください。")
        }
        lines.append("以下の日誌だけを根拠に、質問に答えてください。")
        for item in packed {
            lines.append("")
            lines.append("--- 日誌 (\(formatter.string(from: item.entry.createdAt))) ---")
            lines.append(item.text)
        }
        lines.append("")
        lines.append("質問: \(question)")
        return lines.joined(separator: "\n")
    }

    /// Gregorian `yyyy-MM-dd` in the calendar's time zone, whatever the calendar's identifier.
    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
