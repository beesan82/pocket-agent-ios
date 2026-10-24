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

/// Search terms for "ask the journal": parsed from LLM output, or split from the question.
public enum SearchTerms {
    public static let maxTerms = 8

    /// Accepts a JSON array of strings, possibly wrapped in other text. Anything else is nil.
    public static func parse(llmOutput: String) -> [String]? {
        guard let open = llmOutput.firstIndex(of: "["),
              let close = llmOutput.lastIndex(of: "]"),
              open < close,
              let data = String(llmOutput[open...close]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return clean(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, limit: maxTerms)
    }

    /// Used when the model gave no usable terms: split the question into fragments of 2+ characters.
    public static func fallback(question: String) -> [String] {
        var separators = CharacterSet.whitespacesAndNewlines
        separators.insert(charactersIn: "、。？！?!")
        let fragments = question.components(separatedBy: separators).filter { $0.count >= 2 }
        return clean(fragments, limit: nil)
    }

    /// Question words that are not worth searching for.
    static let questionWords: Set<String> = ["何", "誰", "何時", "何処"]

    /// Terms for the chat's journal lookup, without a model call: the runs of kanji, katakana,
    /// latin letters and digits (hiragana runs are mostly particles and endings, and are dropped),
    /// minus question words. Single-character runs are kept only when they contain kanji.
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
        let kept = runs.filter { run in
            !questionWords.contains(run) && (run.count >= 2 || run.unicodeScalars.contains(where: isKanji))
        }
        return clean(kept, limit: maxTerms)
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

/// Chooses which entries to show the model.
public enum JournalRetrieval {
    public static func select(
        inRange: [JournalEntry]?, hitsByTerm: [[JournalEntry]], recent: [JournalEntry]
    ) -> (entries: [JournalEntry], usedRecentFallback: Bool) {
        let hits = unique(hitsByTerm.flatMap { $0 })
        let chosen: [JournalEntry]
        if let inRange {
            let hitIDs = Set(hits.map(\.id))
            let narrowed = inRange.filter { hitIDs.contains($0.id) }
            chosen = narrowed.isEmpty ? inRange : narrowed
        } else {
            chosen = hits
        }
        let entries = newestFirst(unique(chosen))
        if entries.isEmpty {
            return (recent, true)
        }
        return (entries, false)
    }

    /// Dedupes by id, keeping the first occurrence.
    private static func unique(_ entries: [JournalEntry]) -> [JournalEntry] {
        var seen = Set<UUID>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    static func newestFirst(_ entries: [JournalEntry]) -> [JournalEntry] {
        // Offsets make the order of equal timestamps deterministic (input order).
        entries.enumerated()
            .sorted { $0.element.createdAt != $1.element.createdAt
                ? $0.element.createdAt > $1.element.createdAt : $0.offset < $1.offset }
            .map(\.element)
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

/// Packs entries into a bounded prompt context, newest first.
public enum JournalContextPacker {
    public static func pack(
        _ entries: [JournalEntry], maxEntries: Int = 20, maxCharactersPerEntry: Int = 300,
        maxTotalCharacters: Int = 3000
    ) -> [PackedEntry] {
        var packed: [PackedEntry] = []
        var total = 0
        for entry in JournalRetrieval.newestFirst(entries).prefix(max(0, maxEntries)) {
            let text = truncate((entry.title.map { $0 + "\n" } ?? "") + entry.body, to: maxCharactersPerEntry)
            if total + text.count > maxTotalCharacters { break }
            total += text.count
            packed.append(PackedEntry(entry: entry, text: text))
        }
        return packed
    }

    /// The trailing "…" counts toward the limit.
    private static func truncate(_ text: String, to limit: Int) -> String {
        guard limit >= 1, text.count > limit else { return limit >= 1 ? text : "" }
        return String(text.prefix(limit - 1)) + "…"
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
