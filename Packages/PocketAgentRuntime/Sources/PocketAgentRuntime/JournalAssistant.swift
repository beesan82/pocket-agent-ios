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

/// Journal features on top of any `LLMClient` (an on-device client in the app: MLX or Apple).
/// Retrieval runs in the app; the model only picks search terms and writes the answer.
public struct JournalAssistant: JournalAssisting {
    static let emptyJournalMessage = "日誌がまだありません"
    static let recentLimit = 10

    private let client: any LLMClient
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    /// Upper bound on journal characters in the answer prompt (smaller for small context windows).
    private let contextCharacterBudget: Int

    public init(
        client: any LLMClient, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current,
        contextCharacterBudget: Int = 3000
    ) {
        self.client = client
        self.now = now
        self.calendar = calendar
        self.contextCharacterBudget = contextCharacterBudget
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

    public func ask(_ question: String, store: any JournalStore) async throws -> AskResult {
        guard try await !store.all().isEmpty else {
            return AskResult(evidence: [], usedRecentFallback: false, answer: AsyncThrowingStream {
                $0.yield(Self.emptyJournalMessage)
                $0.finish()
            })
        }

        let range = RelativeDateRange.parse(question, now: now(), calendar: calendar)
        let terms = await searchTerms(for: question)

        var inRange: [JournalEntry]?
        if let range {
            inRange = try await store.entries(in: range)
        }
        var hitsByTerm: [[JournalEntry]] = []
        for term in terms {
            let hits = try await store.search(term)
            hitsByTerm.append(range.map { range in
                hits.filter { $0.createdAt >= range.start && $0.createdAt < range.end }
            } ?? hits)
        }
        let recent = try await store.recent(limit: Self.recentLimit)

        let selection = JournalRetrieval.select(inRange: inRange, hitsByTerm: hitsByTerm, recent: recent)
        let packed = JournalContextPacker.pack(selection.entries, maxTotalCharacters: contextCharacterBudget)
        try Task.checkCancellation()

        let messages: [ChatMessage] = [
            .system(JournalPrompts.answerSystem),
            .user(JournalPrompts.answerUser(
                question: question, packed: packed, usedRecentFallback: selection.usedRecentFallback,
                now: now(), calendar: calendar
            ))
        ]
        let answer = StreamBridge.contentOnly(
            client.stream(messages: messages, tools: [], requestContext: LocalGeneration.requestContext(maxTokens: 384))
        )
        return AskResult(evidence: packed, usedRecentFallback: selection.usedRecentFallback, answer: answer)
    }

    /// Model-picked terms; the question's own fragments when the call fails or gives nothing usable.
    private func searchTerms(for question: String) async -> [String] {
        let messages: [ChatMessage] = [
            .system(JournalPrompts.termsSystem), .user(JournalPrompts.termsUser(question: question))
        ]
        if let reply = try? await client.generate(
            messages: messages, tools: [], responseFormat: nil,
            requestContext: LocalGeneration.requestContext(maxTokens: 64)
        ), let terms = SearchTerms.parse(llmOutput: reply.content), !terms.isEmpty {
            return terms
        }
        return SearchTerms.fallback(question: question)
    }
}
