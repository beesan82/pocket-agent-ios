import AgentRunKit
import Foundation
import PocketAgentCore

/// Journal summaries and meeting notes. App tests substitute a fake.
public protocol JournalAssisting: Sendable {
    func summarize(_ text: String) -> AsyncThrowingStream<String, Error>
    /// Meeting notes rewritten from the previous notes and the transcript since then (full replacement).
    func updateMeetingNotes(previous: String, newText: String) -> AsyncThrowingStream<String, Error>
}

/// Journal features on top of any `LLMClient` (an on-device client in the app: MLX or Apple).
/// Questions about the journal are answered by the chat (`JournalLookup`).
public struct JournalAssistant: JournalAssisting {
    private let client: any LLMClient
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        client: any LLMClient, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current
    ) {
        self.client = client
        self.now = now
        self.calendar = calendar
    }

    public func summarize(_ text: String) -> AsyncThrowingStream<String, Error> {
        let messages: [ChatMessage] = [
            .system(JournalPrompts.summarySystem),
            .user(JournalPrompts.summaryUser(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), recordedAt: now(), calendar: calendar
            ))
        ]
        return StreamBridge.contentOnly(client.stream(messages: messages, tools: [], requestContext: LocalGeneration.requestContext(maxTokens: 512)))
    }

    public func updateMeetingNotes(previous: String, newText: String) -> AsyncThrowingStream<String, Error> {
        let messages: [ChatMessage] = [
            .system(JournalPrompts.meetingNotesSystem),
            .user(JournalPrompts.meetingNotesUser(previous: previous, newText: newText))
        ]
        // Three headings × up to 7 Japanese bullets: 512 would cut the tail off.
        return StreamBridge.contentOnly(
            client.stream(messages: messages, tools: [], requestContext: LocalGeneration.requestContext(maxTokens: 1024)))
    }
}
