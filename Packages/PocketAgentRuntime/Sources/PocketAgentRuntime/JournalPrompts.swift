import Foundation
import PocketAgentCore

/// Prompts for the on-device journal features (summary, search terms, answer).
public enum JournalPrompts {
    public static let summarySystem = ""

    public static func summaryUser(text _: String) -> String { "" }

    public static let termsSystem = ""

    public static func termsUser(question _: String) -> String { "" }

    public static let answerSystem = ""

    public static func answerUser(
        question _: String, packed _: [PackedEntry], usedRecentFallback _: Bool, calendar _: Calendar = .current
    ) -> String { "" }
}
