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
