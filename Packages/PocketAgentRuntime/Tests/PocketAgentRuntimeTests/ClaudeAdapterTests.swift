import AgentRunKit
import Foundation
import Testing
@testable import PocketAgentRuntime

// Not a real credential; chosen so ci/secret-scan.sh never matches it.
private let fakeKey = "test-key"

@Suite(.serialized)
struct ClaudeAdapterTests {
    // AT-01 (Unit part): a plain text reply ends the run in one round trip.
    // Also proves the client is not wrapped: AgentRunKit only stops on text-only
    // replies for its own ContentOnlyTerminatingClient types.
    @Test func textReplyCompletesRunInOneRoundTrip() async throws {
        let session = StubURLProtocol.session(replying: .init(
            status: 200,
            body: #"{"content":[{"type":"text","text":"こんにちは"}]}"#
        ))
        let client = try ClaudeAdapter.makeClient(apiKey: fakeKey, model: ClaudeAdapter.defaultModel, session: session)
        let runner = AgentRunner<EmptyContext>(client: client, tools: [])

        let outcome = try await runner.run("挨拶して", context: EmptyContext()) { _ in .deny(reason: nil) }

        #expect(outcome == .completed("こんにちは"))
        let requests = StubURLProtocol.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.host() == "api.anthropic.com")
        #expect(request.url?.path() == "/v1/messages")
        #expect(request.headers["x-api-key"] == fakeKey)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 1024)
    }

    @Test func clientIsTheSDKAnthropicClient() throws {
        let client = try ClaudeAdapter.makeClient(apiKey: fakeKey, model: "claude-sonnet-5-5")

        #expect(client.providerIdentifier == .anthropic)
        #expect(client.modelIdentifier == "claude-sonnet-5-5")
        #expect(client.maxTokens == ClaudeAdapter.defaultMaxTokens)
    }

    @Test func surroundingWhitespaceIsTrimmed() async throws {
        let session = StubURLProtocol.session(replying: .init(
            status: 200, body: #"{"content":[{"type":"text","text":"ok"}]}"#
        ))
        let client = try ClaudeAdapter.makeClient(apiKey: "  \(fakeKey)\n", model: " claude-sonnet-5-5 ", session: session)

        _ = try await AgentRunner<EmptyContext>(client: client, tools: [])
            .run("hi", context: EmptyContext()) { _ in .deny(reason: nil) }

        #expect(StubURLProtocol.requests.first?.headers["x-api-key"] == fakeKey)
        #expect(client.modelIdentifier == "claude-sonnet-5-5")
    }

    @Test(arguments: ["", "   \n"])
    func blankKeyIsRejected(key: String) {
        #expect(throws: ClaudeAdapter.ConfigurationError.emptyAPIKey) {
            try ClaudeAdapter.makeClient(apiKey: key, model: "claude-sonnet-5-5")
        }
    }

    @Test func blankModelIsRejected() {
        #expect(throws: ClaudeAdapter.ConfigurationError.emptyModel) {
            try ClaudeAdapter.makeClient(apiKey: fakeKey, model: " ")
        }
    }

    // AT-01: invalid key → cause is shown, and nothing from the response body leaks.
    @Test func unauthorizedExplainsKeyWithoutEchoingBody() async throws {
        let session = StubURLProtocol.session(replying: .init(
            status: 401,
            body: #"{"type":"error","error":{"type":"authentication_error","message":"bad key test-key-secret-echo"}}"#
        ))
        let client = try ClaudeAdapter.makeClient(apiKey: fakeKey, model: ClaudeAdapter.defaultModel, session: session)

        let message = await failureMessage {
            _ = try await AgentRunner<EmptyContext>(client: client, tools: [])
                .run("hi", context: EmptyContext()) { _ in .deny(reason: nil) }
        }

        #expect(message.contains("APIキー"))
        #expect(!message.contains("secret-echo"))
        #expect(!message.contains(fakeKey))
        #expect(StubURLProtocol.requests.count == 1) // 401 is not retried
    }

    @Test func describerCoversTransportFailures() {
        let rateLimited = LLMErrorDescriber.userMessage(for: AgentError.llmError(.rateLimited(retryAfter: nil)))
        let offline = LLMErrorDescriber.userMessage(
            for: AgentError.llmError(.networkError(code: .notConnectedToInternet, description: "x"))
        )
        let server = LLMErrorDescriber.userMessage(for: AgentError.llmError(.httpError(statusCode: 529, body: "test-key")))
        let other = LLMErrorDescriber.userMessage(for: CocoaError(.fileNoSuchFile))

        #expect(rateLimited.contains("混雑"))
        #expect(offline.contains("通信"))
        #expect(!server.contains("test-key"))
        #expect(!other.isEmpty)
        #expect(Set([rateLimited, offline, server]).count == 3)
    }
}

private func failureMessage(_ body: () async throws -> Void) async -> String {
    do {
        try await body()
        Issue.record("expected the run to fail")
        return ""
    } catch {
        return LLMErrorDescriber.userMessage(for: error)
    }
}
