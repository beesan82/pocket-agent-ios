import Foundation
import PocketAgentCore

/// Prompts for the on-device journal features (summary, search terms, answer).
public enum JournalPrompts {
    public static let summarySystem = """
    あなたは日誌の要約係です。ユーザーの文章を日本語で要約してください。
    - 箇条書きにせず、1〜3 文にまとめる。
    - 固有名詞・日時・数字は省かない。
    - 出力形式: 1 行目は「見出し: 」に続けて 15 文字以内の見出し、2 行目以降に要約本文。
    - 本文の出来事の時刻は、本文に書かれていればそれに従い、書かれていなければ記録日時より前の出来事として扱い、午前・午後を推測で決めない。
    - それ以外の説明や前置きは書かない。
    """

    public static func summaryUser(text: String, recordedAt: Date, calendar: Calendar = .current) -> String {
        "記録日時: \(stamp(recordedAt, calendar))\n\n次の文章を要約してください。\n\n\(text)"
    }

    public static let termsSystem = """
    あなたは日誌検索の検索語を選ぶ係です。質問から日誌を探すための短い検索語を最大 5 個選んでください。
    - 検索語は質問に含まれる単語か短い句にする。
    - 出力は JSON 配列だけ（例: ["歯医者", "予約"]）。説明や前置きは書かない。
    """

    public static func termsUser(question: String) -> String {
        "質問: \(question)"
    }

    public static let meetingNotesSystem = """
    あなたは会議の書記です。「これまでの要点」と「新しい発言」から、要点を更新して全文を出力してください。
    - 見出しは次の 3 つだけを、この順で必ず書く: 「## 決まったこと」「## 宿題」「## 論点・未決」。
    - 各見出しの下は「- 」で始まる箇条書き。各見出し最大 7 項目。該当がなければ「- （なし）」と書く。
    - 宿題は「- 内容（担当: 〇〇、期限: 〇〇）」の形。担当や期限が分からなければその部分は省く。
    - 固有名詞・数字・日時は省かない。発言に無いことは書かない。
    - これまでの要点にある項目は、新しい発言で変わらない限り残す。
    - 前置き・説明・出力以外の文は書かない。
    """

    public static func meetingNotesUser(previous: String, newText: String) -> String {
        let trimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousBlock = trimmed.isEmpty ? "これまでの要点: （まだありません）" : "これまでの要点:\n\(trimmed)"
        return "\(previousBlock)\n\n新しい発言:\n\(newText)\n\n要点を更新して全文を出力してください。"
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
        var lines: [String] = ["現在日時: \(stamp(now, calendar))"]
        if usedRecentFallback {
            lines.append("質問に合う日誌が見つからなかったため、直近の日誌を渡します。回答は「直近の日誌から：」で始めてください。")
        }
        lines.append("以下の日誌だけを根拠に、質問に答えてください。")
        for item in packed {
            lines.append("")
            lines.append("--- 日誌 (\(format(item.entry.createdAt, "yyyy-MM-dd HH:mm", calendar))) ---")
            lines.append(item.text)
        }
        lines.append("")
        lines.append("質問: \(question)")
        return lines.joined(separator: "\n")
    }

    /// `yyyy-MM-dd HH:mm（曜）` in the calendar's time zone.
    private static func stamp(_ date: Date, _ calendar: Calendar) -> String {
        let weekdays = ["日", "月", "火", "水", "木", "金", "土"]
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let weekday = weekdays[gregorian.component(.weekday, from: date) - 1]
        return "\(format(date, "yyyy-MM-dd HH:mm", calendar))（\(weekday)）"
    }

    /// Fixed-pattern Gregorian formatting in the calendar's time zone, whatever the calendar's identifier.
    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
