import Foundation
import Testing
@testable import PocketAgentCore

struct JournalQueryTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // 2026-10-18 is a Sunday: the last day of a Monday-start week.
    private var now: Date { date(2026, 10, 18, 12) }

    private func range(_ q: String) -> DateInterval? {
        RelativeDateRange.parse(q, now: now, calendar: calendar)
    }

    private func entry(_ body: String, _ t: TimeInterval, id: UUID = UUID(), title: String? = nil) -> JournalEntry {
        JournalEntry(
            id: id, createdAt: Date(timeIntervalSince1970: t), source: .text, origin: .journal,
            body: body, title: title
        )
    }

    // MARK: dates

    @Test func today() {
        #expect(range("今日のこと") == DateInterval(start: date(2026, 10, 18), end: date(2026, 10, 19)))
    }

    @Test func yesterday() {
        #expect(range("昨日何した") == DateInterval(start: date(2026, 10, 17), end: date(2026, 10, 18)))
    }

    @Test func dayBeforeYesterdayIsNotYesterday() {
        #expect(range("一昨日何した") == DateInterval(start: date(2026, 10, 16), end: date(2026, 10, 17)))
    }

    @Test func thisWeekStartsOnMonday() {
        #expect(range("今週の予定") == DateInterval(start: date(2026, 10, 12), end: date(2026, 10, 19)))
    }

    @Test func lastWeek() {
        #expect(range("先週の会議") == DateInterval(start: date(2026, 10, 5), end: date(2026, 10, 12)))
    }

    @Test func thisMonth() {
        #expect(range("今月") == DateInterval(start: date(2026, 10, 1), end: date(2026, 11, 1)))
    }

    @Test func lastMonth() {
        #expect(range("先月") == DateInterval(start: date(2026, 9, 1), end: date(2026, 10, 1)))
    }

    @Test func noDateWordIsNil() {
        #expect(range("会議の件") == nil)
    }

    @Test func firstOccurrenceWins() {
        #expect(range("今月と先週") == DateInterval(start: date(2026, 10, 1), end: date(2026, 11, 1)))
        #expect(range("先週と今月") == DateInterval(start: date(2026, 10, 5), end: date(2026, 10, 12)))
    }

    @Test func weekBoundaryOnMonday() {
        let monday = date(2026, 10, 12, 9)
        let r = RelativeDateRange.parse("今週", now: monday, calendar: calendar)
        #expect(r == DateInterval(start: date(2026, 10, 12), end: date(2026, 10, 19)))
    }

    // MARK: search terms

    @Test func parseAcceptsOnlyStringArrays() {
        #expect(SearchTerms.parse(llmOutput: #"["a","b"]"#) == ["a", "b"])
        #expect(SearchTerms.parse(llmOutput: #"{"a":1}"#) == nil)
        #expect(SearchTerms.parse(llmOutput: "[]") == [])
        #expect(SearchTerms.parse(llmOutput: "[1,2]") == nil)
        #expect(SearchTerms.parse(llmOutput: "not json") == nil)
    }

    @Test func parseToleratesSurroundingText() {
        #expect(SearchTerms.parse(llmOutput: "検索語は次の通り:\n[\"会議\",\"予算\"]\n以上") == ["会議", "予算"])
    }

    @Test func parseTrimsDedupesAndCaps() {
        #expect(SearchTerms.parse(llmOutput: #"[" a ","","a","b"]"#) == ["a", "b"])
        let many = (1...12).map { "\"t\($0)\"" }.joined(separator: ",")
        #expect(SearchTerms.parse(llmOutput: "[\(many)]")?.count == 8)
    }

    @Test func fallbackSplitsOnJapanesePunctuation() {
        #expect(SearchTerms.fallback(question: "先週の会議、どうなった？") == ["先週の会議", "どうなった"])
    }

    @Test func fallbackSplitsWhitespaceDropsShortAndDedupes() {
        #expect(SearchTerms.fallback(question: "a 会議\u{3000}会議 予算!") == ["会議", "予算"])
    }

    // Chat looks the journal up every turn without a model call: keep kanji / katakana / latin runs,
    // drop hiragana runs (particles and endings).
    @Test func keywordsDropParticlesAndQuestionWords() {
        #expect(SearchTerms.keywords(question: "ポチの散歩はいつ？") == ["ポチ", "散歩"])
        #expect(SearchTerms.keywords(question: "先週の会議の結論は？") == ["会議", "結論"])
        #expect(SearchTerms.keywords(question: "うちの犬の名前はココだよ") == ["名前", "ココ"])
    }

    // Review 2026-10-24: a single kanji like 私 matches almost everything, so it is dropped when a
    // longer term exists; date words are handled as the date range, not as terms.
    @Test func keywordsDropSingleKanjiWhenLongerTermsExist() {
        #expect(SearchTerms.keywords(question: "私の予定は？") == ["予定"])
        #expect(SearchTerms.keywords(question: "犬") == ["犬"])
    }

    @Test func keywordsDropRelativeDateWords() {
        #expect(SearchTerms.keywords(question: "今日の予定") == ["予定"])
        #expect(SearchTerms.keywords(question: "昨日と一昨日と先月") == [])
    }

    @Test func keywordsOfAQuestionWordAloneAreEmpty() {
        #expect(SearchTerms.keywords(question: "いつ？") == [])
        #expect(SearchTerms.keywords(question: "何があった？") == [])
    }

    @Test func keywordsDedupeAndCap() {
        #expect(SearchTerms.keywords(question: "歯医者 歯医者 予約") == ["歯医者", "予約"])
        let many = "赤、青、黄、緑、紫、橙、茶、灰、白、黒"
        #expect(SearchTerms.keywords(question: many).count == SearchTerms.maxTerms)
    }

    @Test func keywordsKeepLatinAndDigits() {
        #expect(SearchTerms.keywords(question: "iPhoneの修理は10月?") == ["iPhone", "修理", "10月"])
    }

    // MARK: retrieval

    @Test func dateRangeWithNoTermHitsUsesWholeRange() {
        let a = entry("a", 1), b = entry("b", 2)
        let r = JournalRetrieval.select(inRange: [a, b], hitsByTerm: [[]], recent: [entry("r", 9)])
        #expect(r.entries.map(\.body) == ["b", "a"])
        #expect(r.usedRecentFallback == false)
    }

    @Test func termsNarrowWithinRange() {
        let a = entry("a", 1), b = entry("b", 2), outside = entry("o", 3)
        let r = JournalRetrieval.select(inRange: [a, b], hitsByTerm: [[a, outside]], recent: [])
        #expect(r.entries.map(\.body) == ["a"])
        #expect(r.usedRecentFallback == false)
    }

    @Test func noRangeUnionsHits() {
        let shared = UUID()
        let a = entry("a", 1, id: shared), a2 = entry("a", 1, id: shared), b = entry("b", 5)
        let r = JournalRetrieval.select(inRange: nil, hitsByTerm: [[a, b], [a2]], recent: [entry("r", 9)])
        #expect(r.entries.map(\.body) == ["b", "a"])
        #expect(r.usedRecentFallback == false)
    }

    @Test func emptyEverythingFallsBackToRecent() {
        let recent = [entry("r2", 9), entry("r1", 8)]
        let r1 = JournalRetrieval.select(inRange: nil, hitsByTerm: [[]], recent: recent)
        #expect(r1.entries == recent)
        #expect(r1.usedRecentFallback)
        let r2 = JournalRetrieval.select(inRange: [], hitsByTerm: [], recent: recent)
        #expect(r2.entries == recent)
        #expect(r2.usedRecentFallback)
    }

    @Test func tiesKeepInputOrder() {
        let a = entry("a", 1), b = entry("b", 1)
        let r = JournalRetrieval.select(inRange: nil, hitsByTerm: [[a, b]], recent: [])
        #expect(r.entries.map(\.body) == ["a", "b"])
    }

    // MARK: packing

    @Test func packRespectsAllThreeLimits() {
        let entries = (1...30).map { entry("x", Double($0)) }
        #expect(JournalContextPacker.pack(entries).count == 20)
        #expect(JournalContextPacker.pack(entries, maxEntries: 5).count == 5)

        let long = entry(String(repeating: "あ", count: 500), 1)
        let packedLong = JournalContextPacker.pack([long])
        #expect(packedLong.first?.text.count == 300)
        #expect(packedLong.first?.text.hasSuffix("…") == true)

        let three = (1...3).map { entry(String(repeating: "い", count: 100), Double($0)) }
        let packed = JournalContextPacker.pack(three, maxTotalCharacters: 250)
        #expect(packed.count == 2)
        #expect(packed.map(\.text.count).reduce(0, +) <= 250)
    }

    @Test func packIsNewestFirstAndIncludesTitle() {
        let old = entry("old", 1), new = entry("new", 2, title: "題")
        let packed = JournalContextPacker.pack([old, new])
        #expect(packed.map(\.text) == ["題\nnew", "old"])
    }

    @Test func packKeepsShortTextUncut() {
        #expect(JournalContextPacker.pack([entry("abc", 1)]).first?.text == "abc")
    }

    // MARK: summary

    @Test func parseTitleLine() {
        #expect(SummaryParser.parse("見出し: 会議メモ\n本文です。") == SummaryOutput(title: "会議メモ", body: "本文です。"))
        #expect(SummaryParser.parse("見出し：全角\n行1\n行2") == SummaryOutput(title: "全角", body: "行1\n行2"))
        let long = SummaryParser.parse("見出し: " + String(repeating: "あ", count: 20) + "\n本文")
        #expect(long.title == String(repeating: "あ", count: 15))
        #expect(SummaryParser.parse("見出し:\n本文") == SummaryOutput(title: nil, body: "本文"))
        #expect(SummaryParser.parse("  ただの本文  ") == SummaryOutput(title: nil, body: "ただの本文"))
    }
}
