import Foundation

/// Maps a relative-date word in a question to a date range.
public enum RelativeDateRange {
    private enum Word: CaseIterable {
        case today, dayBeforeYesterday, yesterday, thisWeek, lastWeek, thisMonth, lastMonth

        var text: String {
            switch self {
            case .today: "今日"
            case .dayBeforeYesterday: "一昨日"
            case .yesterday: "昨日"
            case .thisWeek: "今週"
            case .lastWeek: "先週"
            case .thisMonth: "今月"
            case .lastMonth: "先月"
            }
        }
    }

    /// The word that occurs earliest in the question wins, so 一昨日 beats the 昨日 inside it.
    public static func parse(_ question: String, now: Date, calendar: Calendar) -> DateInterval? {
        var best: (word: Word, index: String.Index)?
        for word in Word.allCases {
            guard let found = question.range(of: word.text) else { continue }
            if best == nil || found.lowerBound < best!.index {
                best = (word, found.lowerBound)
            }
        }
        guard let word = best?.word else { return nil }

        switch word {
        case .today:
            return day(containing: now, offset: 0, calendar: calendar)
        case .dayBeforeYesterday:
            return day(containing: now, offset: -2, calendar: calendar)
        case .yesterday:
            return day(containing: now, offset: -1, calendar: calendar)
        case .thisWeek:
            return span(.weekOfYear, containing: now, offset: 0, calendar: calendar)
        case .lastWeek:
            return span(.weekOfYear, containing: now, offset: -1, calendar: calendar)
        case .thisMonth:
            return span(.month, containing: now, offset: 0, calendar: calendar)
        case .lastMonth:
            return span(.month, containing: now, offset: -1, calendar: calendar)
        }
    }

    private static func day(containing now: Date, offset: Int, calendar: Calendar) -> DateInterval? {
        guard let shifted = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        return calendar.dateInterval(of: .day, for: shifted)
    }

    private static func span(
        _ component: Calendar.Component, containing now: Date, offset: Int, calendar: Calendar
    ) -> DateInterval? {
        guard let shifted = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
        return calendar.dateInterval(of: component, for: shifted)
    }
}

/// Search terms for a journal question, split from the question for the chat's lookup.
public enum SearchTerms {
    public static let maxTerms = 12

    /// Question words that are not worth searching for.
    static let questionWords: Set<String> = ["何", "誰", "何時", "何処"]
    /// Date words become the date range (`RelativeDateRange`), not search terms.
    static let dateWords: Set<String> = ["今日", "一昨日", "昨日", "今週", "先週", "今月", "先月"]

    /// Terms for the chat's journal lookup, without a model call: the runs of kanji, katakana,
    /// latin letters and digits (hiragana runs are mostly particles and endings, and are dropped),
    /// minus question and date words. Single-character runs are kept only when they are kanji and
    /// no longer term exists (a lone 私 or 朝 matches almost every entry). A run of three or more
    /// kanji is followed by its two-character parts (宿泊先 → 宿泊, 泊先): a compound word in the
    /// question rarely appears as is in an entry, while a part of it (ホテルに宿泊) often does.
    public static func keywords(question: String) -> [String] {
        var runs: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { runs.append(current) }
            current = ""
        }
        for scalar in question.unicodeScalars {
            if isKeywordScalar(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        let candidates = runs.filter { run in
            !questionWords.contains(run) && !dateWords.contains(run)
                && (run.count >= 2 || run.unicodeScalars.contains(where: isKanji))
        }
        let hasLongerTerm = candidates.contains { $0.count >= 2 }
        let kept = hasLongerTerm ? candidates.filter { $0.count >= 2 } : candidates
        return clean(kept.flatMap { [$0] + kanjiParts(of: $0) }, limit: maxTerms)
    }

    /// The two-character windows of a run made only of kanji, when it has three or more.
    private static func kanjiParts(of run: String) -> [String] {
        let scalars = Array(run.unicodeScalars)
        guard scalars.count >= 3, scalars.allSatisfy(isKanji) else { return [] }
        return (0 ..< scalars.count - 1).map { start in
            var part = String.UnicodeScalarView()
            part.append(contentsOf: scalars[start ..< start + 2])
            return String(part)
        }
    }

    private static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
            || scalar.value == 0x3005 // 々
    }

    private static func isKeywordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        let katakana = (0x30A0...0x30FF).contains(v) && v != 0x30FB // ・ separates
        let halfwidthKatakana = (0xFF66...0xFF9F).contains(v)
        let latinOrDigit = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            || (0xFF10...0xFF19).contains(v) || (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v)
        return isKanji(scalar) || katakana || halfwidthKatakana || latinOrDigit
    }

    private static func clean(_ terms: [String], limit: Int?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms where !term.isEmpty && seen.insert(term).inserted {
            result.append(term)
            if let limit, result.count == limit { break }
        }
        return result
    }
}

public struct PackedEntry: Equatable, Sendable {
    public let entry: JournalEntry
    public let text: String

    public init(entry: JournalEntry, text: String) {
        self.entry = entry
        self.text = text
    }
}

public struct SummaryOutput: Equatable, Sendable {
    public let title: String?
    public let body: String

    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }
}

public enum SummaryParser {
    public static let maxTitleLength = 15

    /// First line `見出し:`/`見出し：` becomes the title; the rest is the body.
    public static func parse(_ output: String) -> SummaryOutput {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first else { return SummaryOutput(title: nil, body: "") }
        for prefix in ["見出し:", "見出し："] where first.hasPrefix(prefix) {
            let title = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = lines.count > 1 ? String(lines[1]) : ""
            return SummaryOutput(
                title: title.isEmpty ? nil : String(title.prefix(maxTitleLength)),
                body: rest.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return SummaryOutput(title: nil, body: trimmed)
    }
}
