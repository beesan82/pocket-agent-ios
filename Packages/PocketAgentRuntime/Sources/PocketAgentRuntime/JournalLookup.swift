import Foundation
import PocketAgentCore

/// How many characters the chat's journal section may take, including its header, date line and
/// each line's "- [date] " prefix (the memo section, folded turns and tool definitions share the
/// same context, so on-device budgets are smaller than 日誌に聞く's were).
public struct JournalLookupBudget: Sendable, Equatable {
    public let maxTotalCharacters: Int

    public init(maxTotalCharacters: Int) {
        self.maxTotalCharacters = maxTotalCharacters
    }

    public static let claude = JournalLookupBudget(maxTotalCharacters: 6000)
    /// 800 (2026-10-24) held two entries at most, so the model saw nothing for older questions.
    public static let appleLocal = JournalLookupBudget(maxTotalCharacters: 1200)
    public static let mlxLocal = JournalLookupBudget(maxTotalCharacters: 1500)
}

/// The chat's journal lookup (日誌に聞く merged into chat, 2026-10-24): a date range from the
/// question, narrowed by its words, without a model call. Journal entries only (saved memos are in
/// the memo section every turn). Nothing specific found → empty (the recent entries are already in
/// the memo section). The store is read once per turn and the words are matched in memory, ranked
/// by how many of them an entry contains, then newest first.
public enum JournalLookup {
    public static let maxCharactersPerEntry = 300
    /// "\n- [yyyy-MM-dd HH:mm] " before each entry in `ConversationContext.journalLookupSection`.
    static let lineOverhead = 22
    /// The header line, "\n" and "現在日時: yyyy-MM-dd HH:mm（曜）".
    static var sectionOverhead: Int { ConversationContext.journalLookupHeader.count + 1 + 25 }
    /// Characters of transcript shown around a hit that only the transcript has (150 in total).
    static let excerptBefore = 60
    static let excerptAfter = 90

    public static func find(
        question: String, store: any JournalStore, now: Date, calendar: Calendar, budget: JournalLookupBudget
    ) async throws -> [PackedEntry] {
        let range = RelativeDateRange.parse(question, now: now, calendar: calendar)
        let terms = SearchTerms.keywords(question: question)
        guard range != nil || !terms.isEmpty else { return [] }

        let candidates: [JournalEntry]
        if let range {
            candidates = try await store.entries(in: range).filter(isJournal)
        } else {
            candidates = try await store.all().filter(isJournal)
        }
        let hits = candidates.compactMap { entry -> (entry: JournalEntry, score: Int)? in
            let score = terms.filter { matches(entry, $0) }.count
            return score > 0 ? (entry, score) : nil
        }
        let chosen: [JournalEntry]
        if hits.isEmpty {
            // A date range with no word hits: the whole range; no range and no hits: nothing.
            chosen = range == nil ? [] : newestFirst(candidates)
        } else {
            chosen = hits.enumerated().sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
                if lhs.element.entry.createdAt != rhs.element.entry.createdAt {
                    return lhs.element.entry.createdAt > rhs.element.entry.createdAt
                }
                return lhs.offset < rhs.offset
            }.map(\.element.entry)
        }

        var packed: [PackedEntry] = []
        var total = sectionOverhead
        for entry in chosen {
            let text = render(entry, terms: terms)
            if total + lineOverhead + text.count > budget.maxTotalCharacters { break }
            total += lineOverhead + text.count
            packed.append(PackedEntry(entry: entry, text: text))
        }
        return packed
    }

    private static func isJournal(_ entry: JournalEntry) -> Bool { entry.origin == .journal }

    /// Same matching as the stores' search (case- and width-insensitive) over body, title and transcript.
    private static func matches(_ entry: JournalEntry, _ term: String) -> Bool {
        entry.body.localizedStandardContains(term) || (entry.title?.localizedStandardContains(term) ?? false)
            || (entry.transcript?.localizedStandardContains(term) ?? false)
    }

    private static func newestFirst(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.enumerated().sorted { lhs, rhs in
            lhs.element.createdAt != rhs.element.createdAt
                ? lhs.element.createdAt > rhs.element.createdAt : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// One line: title, a transcript excerpt around a matched word, then the body. The summary
    /// can mention a category (for example, a hotel) while omitting the name in the original.
    static func render(_ entry: JournalEntry, terms: [String]) -> String {
        var parts: [String] = []
        if let transcript = entry.transcript {
            if let excerpt = excerpt(of: transcript, around: terms) {
                parts.append("（文字起こしより）…" + excerpt + "…")
            }
        }
        parts.append(entry.body)
        var text = flattened(parts.joined(separator: " "))
        if let title = entry.title.map(flattened), !title.isEmpty {
            text = title + ": " + text
        }
        guard text.count > maxCharactersPerEntry else { return text }
        return String(text.prefix(maxCharactersPerEntry - 1)) + "…"
    }

    private static func excerpt(of transcript: String, around terms: [String]) -> String? {
        guard let hit = terms.compactMap({ transcript.localizedStandardRange(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let start = transcript.index(hit.lowerBound, offsetBy: -excerptBefore, limitedBy: transcript.startIndex)
            ?? transcript.startIndex
        let end = transcript.index(hit.upperBound, offsetBy: excerptAfter, limitedBy: transcript.endIndex)
            ?? transcript.endIndex
        return String(transcript[start..<end])
    }

    static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
