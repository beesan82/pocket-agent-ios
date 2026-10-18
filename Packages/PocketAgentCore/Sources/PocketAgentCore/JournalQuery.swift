import Foundation

/// Maps a relative-date word in a question to a date range.
public enum RelativeDateRange {
    public static func parse(_ question: String, now: Date, calendar: Calendar) -> DateInterval? {
        nil
    }
}

/// Search terms for "ask the journal": parsed from LLM output, or split from the question.
public enum SearchTerms {
    public static func parse(llmOutput: String) -> [String]? {
        nil
    }

    public static func fallback(question: String) -> [String] {
        []
    }
}

/// Chooses which entries to show the model.
public enum JournalRetrieval {
    public static func select(
        inRange: [JournalEntry]?, hitsByTerm: [[JournalEntry]], recent: [JournalEntry]
    ) -> (entries: [JournalEntry], usedRecentFallback: Bool) {
        ([], false)
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
        []
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
    public static func parse(_ output: String) -> SummaryOutput {
        SummaryOutput(title: nil, body: "")
    }
}
