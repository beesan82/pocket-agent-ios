import Foundation
import PocketAgentCore

/// How many journal characters a chat turn may carry (the memo section, folded turns and tool
/// definitions share the same context, so on-device budgets are smaller than 日誌に聞く's were).
public struct JournalLookupBudget: Sendable, Equatable {
    public let maxTotalCharacters: Int

    public init(maxTotalCharacters: Int) {
        self.maxTotalCharacters = maxTotalCharacters
    }

    public static let claude = JournalLookupBudget(maxTotalCharacters: 6000)
    public static let appleLocal = JournalLookupBudget(maxTotalCharacters: 800)
    public static let mlxLocal = JournalLookupBudget(maxTotalCharacters: 1500)
}

/// The chat's journal lookup (日誌に聞く merged into chat, 2026-10-24): the same two steps — a date
/// range from the question, narrowed by its words — without a model call. Journal entries only
/// (saved memos are in the memo section every turn). Nothing specific found → empty (the recent
/// entries are already in the memo section).
public enum JournalLookup {
    public static let maxCharactersPerEntry = 300
    /// Characters of transcript shown around a hit that only the transcript has.
    static let excerptBefore = 60
    static let excerptAfter = 90

    public static func find(
        question: String, store: any JournalStore, now: Date, calendar: Calendar, budget: JournalLookupBudget
    ) async throws -> [PackedEntry] {
        let range = RelativeDateRange.parse(question, now: now, calendar: calendar)
        let terms = SearchTerms.keywords(question: question)
        guard range != nil || !terms.isEmpty else { return [] }

        let inRange = try await range.map { try await store.entries(in: $0).filter(isJournal) }
        var hitsByTerm: [[JournalEntry]] = []
        for term in terms {
            let hits = try await store.search(term).filter(isJournal)
            hitsByTerm.append(range.map { range in
                hits.filter { $0.createdAt >= range.start && $0.createdAt < range.end }
            } ?? hits)
        }
        let selection = JournalRetrieval.select(inRange: inRange, hitsByTerm: hitsByTerm, recent: [])
        guard !selection.usedRecentFallback else { return [] }

        var packed: [PackedEntry] = []
        var total = 0
        for entry in selection.entries {
            let text = render(entry, terms: terms)
            if total + text.count > budget.maxTotalCharacters { break }
            total += text.count
            packed.append(PackedEntry(entry: entry, text: text))
        }
        return packed
    }

    private static func isJournal(_ entry: JournalEntry) -> Bool { entry.origin == .journal }

    /// One line: title, a transcript excerpt when only the transcript has a term, then the body.
    static func render(_ entry: JournalEntry, terms: [String]) -> String {
        var parts: [String] = []
        let shown = (entry.title ?? "") + "\n" + entry.body
        if let transcript = entry.transcript, !terms.contains(where: { shown.contains($0) }),
           let excerpt = excerpt(of: transcript, around: terms) {
            parts.append("（文字起こしより）…" + excerpt + "…")
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
        guard let hit = terms.compactMap({ transcript.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound })
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
