import Foundation

/// The languages a meeting can use. Adding a language is one more row in `all`
/// (the speech recognizer and Apple Translation must support its locale).
public struct MeetingLanguage: Sendable, Hashable, Identifiable {
    /// BCP-47 language code used everywhere else ("ja", "en", "zh").
    public let code: String
    /// Shown in the pickers and column headers, in the language itself.
    public let displayName: String
    /// The speech recognizer's locale.
    public let localeIdentifier: String
    /// Put before an utterance of this language in the saved transcript ("" for Japanese).
    public let transcriptMark: String

    public var id: String { code }

    public init(code: String, displayName: String, localeIdentifier: String, transcriptMark: String) {
        self.code = code
        self.displayName = displayName
        self.localeIdentifier = localeIdentifier
        self.transcriptMark = transcriptMark
    }

    public static let all: [MeetingLanguage] = [
        MeetingLanguage(code: "ja", displayName: "日本語", localeIdentifier: "ja_JP", transcriptMark: ""),
        MeetingLanguage(code: "en", displayName: "English", localeIdentifier: "en_US", transcriptMark: "(EN) "),
        // Mandarin, Simplified Chinese (mainland). Traditional (Taiwan) is not offered yet.
        MeetingLanguage(code: "zh", displayName: "中文", localeIdentifier: "zh_CN", transcriptMark: "(ZH) "),
    ]

    public static func named(_ code: String) -> MeetingLanguage? {
        all.first { $0.code == code }
    }
}
