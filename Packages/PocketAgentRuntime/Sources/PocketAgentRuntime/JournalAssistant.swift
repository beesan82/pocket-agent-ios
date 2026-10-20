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

/// Journal features on top of any `LLMClient` (the on-device MLX client in the app).
/// Retrieval runs in the app; the model only picks search terms and writes the answer.
public struct JournalAssistant: JournalAssisting {
    static let emptyJournalMessage = "日誌がまだありません"
    static let recentLimit = 10

    private let client: any LLMClient
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(client: any LLMClient, now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .current) {
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
        return Self.contentOnly(client.stream(messages: messages, tools: [], requestContext: Self.context(maxTokens: 512)))
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
        let packed = JournalContextPacker.pack(selection.entries)
        try Task.checkCancellation()

        let messages: [ChatMessage] = [
            .system(JournalPrompts.answerSystem),
            .user(JournalPrompts.answerUser(
                question: question, packed: packed, usedRecentFallback: selection.usedRecentFallback,
                now: now(), calendar: calendar
            ))
        ]
        let answer = Self.contentOnly(
            client.stream(messages: messages, tools: [], requestContext: Self.context(maxTokens: 384))
        )
        return AskResult(evidence: packed, usedRecentFallback: selection.usedRecentFallback, answer: answer)
    }

    /// Model-picked terms; the question's own fragments when the call fails or gives nothing usable.
    private func searchTerms(for question: String) async -> [String] {
        let messages: [ChatMessage] = [
            .system(JournalPrompts.termsSystem), .user(JournalPrompts.termsUser(question: question))
        ]
        if let reply = try? await client.generate(
            messages: messages, tools: [], responseFormat: nil, requestContext: Self.context(maxTokens: 64)
        ), let terms = SearchTerms.parse(llmOutput: reply.content), !terms.isEmpty {
            return terms
        }
        return SearchTerms.fallback(question: question)
    }

    static func context(maxTokens: Int) -> RequestContext {
        RequestContext(extraFields: [
            "temperature": .double(0.7),
            "top_p": .double(0.8),
            "max_tokens": .int(maxTokens),
            "repetition_penalty": .double(1.1)
        ])
    }

    /// Forwards `.content` text only. Ending the returned stream (e.g. cancelling its consumer)
    /// cancels the pump, which ends iteration of `upstream` and so the model call.
    static func contentOnly(_ upstream: AsyncThrowingStream<StreamDelta, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await delta in upstream {
                        if case let .content(text) = delta {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
