import Foundation
import Testing
@testable import PocketAgentCore

struct MeetingTranscriptTests {
    @Test func timestampUnderOneHour() {
        #expect(MeetingTranscriptFormatter.timestamp(65) == "01:05")
        #expect(MeetingTranscriptFormatter.timestamp(0) == "00:00")
        #expect(MeetingTranscriptFormatter.timestamp(599.9) == "09:59")
    }

    @Test func timestampPastOneHour() {
        #expect(MeetingTranscriptFormatter.timestamp(3605) == "1:00:05")
    }

    @Test func textJoinsLinesWithTimestamps() {
        let segments = [
            TranscriptSegment(offset: 3, text: "おはよう"),
            TranscriptSegment(offset: 70, text: "始めます")
        ]
        #expect(MeetingTranscriptFormatter.text(segments) == "[00:03] おはよう\n[01:10] 始めます")
        #expect(MeetingTranscriptFormatter.text([]) == "")
    }

    @Test func textIncludesLanguageMarkAndTranslation() {
        let segments = [
            TranscriptSegment(offset: 1, text: "こんにちは", language: "ja", translation: "Hello"),
            TranscriptSegment(offset: 5, text: "Thanks", language: "en", translation: "ありがとう"),
            TranscriptSegment(offset: 9, text: "Pending", language: "en"),
        ]
        #expect(MeetingTranscriptFormatter.text(segments)
            == "[00:01] こんにちは\n    → Hello\n[00:05] (EN) Thanks\n    → ありがとう\n[00:09] (EN) Pending")
    }

    @Test func japaneseSidePrefersTranslationForEnglish() {
        #expect(TranscriptSegment(offset: 0, text: "Thanks", language: "en", translation: "ありがとう").japaneseSide == "ありがとう")
        #expect(TranscriptSegment(offset: 0, text: "Thanks", language: "en").japaneseSide == "Thanks")
        #expect(TranscriptSegment(offset: 0, text: "はい", language: "ja", translation: "Yes").japaneseSide == "はい")
        let translated = TranscriptSegment(offset: 3, text: "Hi", language: "en").withTranslation("やあ")
        #expect(translated.translation == "やあ")
        #expect(translated.offset == 3)
    }

    @Test func chineseMarkAndTranslationLanguage() {
        let segments = [
            TranscriptSegment(offset: 2, text: "我们下周开会", language: "zh").withTranslation("来週会議をします", language: "ja"),
            TranscriptSegment(offset: 6, text: "Sounds good", language: "en").withTranslation("好的", language: "zh"),
        ]
        #expect(MeetingTranscriptFormatter.text(segments)
            == "[00:02] (ZH) 我们下周开会\n    → 来週会議をします\n[00:06] (EN) Sounds good\n    → 好的")
        #expect(segments[0].translationLanguage == "ja")
    }

    @Test func japaneseSideOnlyUsesJapaneseTranslations() {
        let zhToJa = TranscriptSegment(offset: 0, text: "好的", language: "zh").withTranslation("了解", language: "ja")
        let enToZh = TranscriptSegment(offset: 0, text: "Sounds good", language: "en").withTranslation("好的", language: "zh")
        #expect(zhToJa.japaneseSide == "了解")
        #expect(enToZh.japaneseSide == "Sounds good")
    }

    @Test func languageTableHasJapaneseEnglishChinese() {
        #expect(MeetingLanguage.all.map(\.code) == ["ja", "en", "zh"])
        #expect(MeetingLanguage.named("zh")?.localeIdentifier == "zh_CN")
        #expect(MeetingLanguage.named("fr") == nil)
    }

    @Test func autoUpdateNeedsAllConditions() {
        #expect(MeetingNotesPolicy.minPendingCharacters == 300)
        #expect(MeetingNotesPolicy.minInterval == 60)
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 300, secondsSinceLastUpdate: nil, isForeground: true, modelReady: true, isUpdating: false))
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 299, secondsSinceLastUpdate: nil, isForeground: true, modelReady: true, isUpdating: false) == false)
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 300, secondsSinceLastUpdate: 59, isForeground: true, modelReady: true, isUpdating: false) == false)
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 300, secondsSinceLastUpdate: 60, isForeground: true, modelReady: true, isUpdating: false))
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 300, secondsSinceLastUpdate: nil, isForeground: false, modelReady: true, isUpdating: false) == false)
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 300, secondsSinceLastUpdate: nil, isForeground: true, modelReady: false, isUpdating: false) == false)
        #expect(MeetingNotesPolicy.shouldAutoUpdate(
            pendingCharacters: 300, secondsSinceLastUpdate: nil, isForeground: true, modelReady: true, isUpdating: true) == false)
    }

    @Test func manualUpdateNeedsOnlyPendingAndModel() {
        #expect(MeetingNotesPolicy.shouldManualUpdate(pendingCharacters: 1, modelReady: true, isUpdating: false))
        #expect(MeetingNotesPolicy.shouldManualUpdate(pendingCharacters: 0, modelReady: true, isUpdating: false) == false)
        #expect(MeetingNotesPolicy.shouldManualUpdate(pendingCharacters: 1, modelReady: false, isUpdating: false) == false)
        #expect(MeetingNotesPolicy.shouldManualUpdate(pendingCharacters: 1, modelReady: true, isUpdating: true) == false)
    }

    @Test func notesCompletenessRequiresAllThreeHeadings() {
        #expect(MeetingNotesPolicy.isComplete("## 決まったこと\n- A\n## 宿題\n- （なし）\n## 論点・未決\n- B"))
        #expect(MeetingNotesPolicy.isComplete("## 決まったこと\n- A\n## 宿題\n- B") == false)
        #expect(MeetingNotesPolicy.isComplete("") == false)
    }

    @Test func titleUsesMonthDayHourMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14, minute: 5)))
        #expect(MeetingTitle.make(start: start, calendar: calendar) == "会議 10/19 14:05")
    }
}
