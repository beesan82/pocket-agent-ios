import AgentRunKit
import Foundation
import PocketAgentCore

public struct AskResult: Sendable {
    public let evidence: [PackedEntry]
    public let usedRecentFallback: Bool
    public let answer: AsyncThrowingStream<String, Error>

    public init(evidence: [PackedEntry], usedRecentFallback: Bool, answer: AsyncThrowingStream<String, Error>) {
        self.evidence = evidence
        self.usedRecentFallback = usedRecentFallback
        self.answer = answer
    }
}

/// Summarize and "ask the journal". App tests substitute a fake.
public protocol JournalAssisting: Sendable {
    func summarize(_ text: String) -> AsyncThrowingStream<String, Error>
    func ask(_ question: String, store: any JournalStore) async throws -> AskResult
}

public struct JournalAssistant: JournalAssisting {
    private let client: any LLMClient
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(client: any LLMClient, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
        self.client = client
        self.now = now
        self.calendar = calendar
    }

    public func summarize(_: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    public func ask(_: String, store _: any JournalStore) async throws -> AskResult {
        AskResult(evidence: [], usedRecentFallback: false, answer: AsyncThrowingStream { $0.finish() })
    }
}
