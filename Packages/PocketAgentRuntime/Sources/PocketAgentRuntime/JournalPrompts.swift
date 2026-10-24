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
