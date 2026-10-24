import Foundation

/// One utterance of a meeting: what was said, when (seconds from the start), in which language,
/// and (bilingual meetings) its translation into the other language. The unit for notes and translation.
public struct TranscriptSegment: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let offset: TimeInterval
    public let text: String
    /// "ja" or "en".
    public let language: String
    public let translation: String?

    public init(
        id: UUID = UUID(), offset: TimeInterval, text: String, language: String = "ja", translation: String? = nil
    ) {
        self.id = id
        self.offset = offset
        self.text = text
        self.language = language
        self.translation = translation
    }

    public func withTranslation(_ translation: String) -> TranscriptSegment {
        TranscriptSegment(id: id, offset: offset, text: text, language: language, translation: translation)
    }

    /// The language the utterance would be translated into.
    public var otherLanguage: String { language == "en" ? "ja" : "en" }

    /// The Japanese text of the utterance: the original, or for English the translation when there is one.
    public var japaneseSide: String {
        language == "en" ? (translation ?? text) : text
    }
}

public enum MeetingTranscriptFormatter {
    /// `mm:ss` under an hour, `h:mm:ss` from one hour on; fractions are dropped.
    public static func timestamp(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The whole meeting as `[mm:ss] text` lines (what the journal stores as the transcript).
    /// English originals are marked `(EN)`; a translation follows on its own `    → ` line.
    public static func text(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let mark = segment.language == "en" ? "(EN) " : ""
            var line = "[\(timestamp(segment.offset))] \(mark)\(segment.text)"
            if let translation = segment.translation, !translation.isEmpty {
                line += "\n    → \(translation)"
            }
            return line
        }
        .joined(separator: "\n")
    }
}

/// When the meeting notes are (re)generated from the transcript.
public enum MeetingNotesPolicy {
    public static let minPendingCharacters = 300
    public static let minInterval: TimeInterval = 60

    /// Automatic update: enough new text, not too soon after the last update (none yet counts as
    /// long enough), the app in front, a usable model, and no update running.
    public static func shouldAutoUpdate(
        pendingCharacters: Int, secondsSinceLastUpdate: TimeInterval?, isForeground: Bool,
        modelReady: Bool, isUpdating: Bool
    ) -> Bool {
        guard isForeground, modelReady, !isUpdating else { return false }
        guard pendingCharacters >= minPendingCharacters else { return false }
        if let secondsSinceLastUpdate, secondsSinceLastUpdate < minInterval { return false }
        return true
    }

    /// The 「更新」 button: anything new, a usable model, and no update running.
    public static func shouldManualUpdate(pendingCharacters: Int, modelReady: Bool, isUpdating: Bool) -> Bool {
        modelReady && !isUpdating && pendingCharacters >= 1
    }

    public static let requiredHeadings = ["## 決まったこと", "## 宿題", "## 論点・未決"]

    /// Output cut off by the token limit loses its tail; only notes with all three headings replace the previous ones.
    public static func isComplete(_ notes: String) -> Bool {
        requiredHeadings.allSatisfy { notes.contains($0) }
    }
}

public enum MeetingTitle {
    /// `会議 M/d HH:mm` in the calendar's time zone.
    public static func make(start: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d HH:mm"
        return "会議 " + formatter.string(from: start)
    }
}
