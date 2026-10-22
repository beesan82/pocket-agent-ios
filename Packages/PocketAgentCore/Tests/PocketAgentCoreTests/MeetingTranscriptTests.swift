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
