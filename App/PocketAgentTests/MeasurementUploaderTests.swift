import Foundation
import Testing
@testable import PocketAgent

@Suite(.serialized)
struct MeasurementUploaderTests {
    private let token = "test-token-123"
    private let repository = "owner/private-repo"
    private let title = "測定ログ 2026-10-19 12:00 iPhone15,4"

    private func created(_ number: Int = 7) -> StubURLProtocol.Reply {
        .http(status: 201, headers: [:], body: "{\"number\": \(number), \"title\": \"x\"}")
    }

    private func upload(_ replies: [StubURLProtocol.Reply], log: String = "# log\nline") async -> UploadResult {
        let uploader = MeasurementUploader(session: StubURLProtocol.session(replying: replies))
        return await uploader.upload(log: log, title: title, repository: repository, token: token)
    }

    private func jsonBody(_ request: StubURLProtocol.Captured) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func postsIssueWithHeadersAndJSON() async throws {
        let result = await upload([created()], log: "# log\nline")

        #expect(result == .created(issueNumber: 7))
        #expect(StubURLProtocol.requests.count == 1)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/owner/private-repo/issues")
        #expect(request.headers["Authorization"] == "Bearer test-token-123")
        #expect(request.headers["Accept"] == "application/vnd.github+json")
        #expect(request.headers["X-GitHub-Api-Version"] == "2022-11-28")
        #expect(request.headers["Content-Type"] == "application/json")
        let json = try jsonBody(request)
        #expect(json["title"] as? String == title)
        #expect(json["body"] as? String == "# log\nline")
        #expect(json["labels"] as? [String] == ["measurement"])
    }

    @Test func createdReturnsIssueNumber() async {
        #expect(await upload([created(42)]) == .created(issueNumber: 42))
    }

    @Test func createdWithoutNumberIsBadResponse() async {
        let reply = StubURLProtocol.Reply.http(status: 201, headers: [:], body: "{}")
        #expect(await upload([reply]) == .failed(.badResponse))
    }

    @Test func statusMapping() async {
        func reply(_ status: Int, _ headers: [String: String] = [:]) -> StubURLProtocol.Reply {
            .http(status: status, headers: headers, body: "{\"message\":\"x\"}")
        }
        #expect(await upload([reply(401)]) == .failed(.unauthorized))
        #expect(await upload([reply(403)]) == .failed(.unauthorized))
        #expect(await upload([reply(403, ["x-ratelimit-remaining": "0"])]) == .failed(.rateLimited))
        #expect(await upload([reply(404)]) == .failed(.notFound))
        #expect(await upload([reply(429)]) == .failed(.rateLimited))
        #expect(await upload([reply(500)]) == .failed(.server(500)))
    }

    @Test func networkErrorMapsToNetwork() async {
        #expect(await upload([.failure]) == .failed(.network))
    }

    @Test func unprocessableRetriesWithoutLabels() async throws {
        let first = StubURLProtocol.Reply.http(status: 422, headers: [:], body: "{}")
        let result = await upload([first, created(9)])

        #expect(result == .created(issueNumber: 9))
        let requests = StubURLProtocol.requests
        #expect(requests.count == 2)
        #expect(try jsonBody(requests[0])["labels"] != nil)
        let retry = try jsonBody(requests[1])
        #expect(retry["labels"] == nil)
        #expect(retry["title"] as? String == title)
    }

    @Test func repeatedUnprocessableMapsToServer() async {
        let reply = StubURLProtocol.Reply.http(status: 422, headers: [:], body: "{}")
        #expect(await upload([reply]) == .failed(.server(422)))
        #expect(StubURLProtocol.requests.count == 2)
    }

    @Test func longLogIsTruncatedKeepingHeaderAndNewest() async throws {
        let header = ["# Pocket Agent 測定ログ", "端末: iPhone15,4 / iOS 26.0", "アプリ: 1.0 (7)", "生成: 2026-10-19 12:00"]
        let lines = (0..<5000).map { "[12:00:00] line-\($0) " + String(repeating: "あ", count: 20) }
        let log = (header + lines).joined(separator: "\n")
        #expect(log.count > 60_000)

        let result = await upload([created()], log: log)

        #expect(result == .created(issueNumber: 7))
        let request = try #require(StubURLProtocol.requests.first)
        let body = try #require(try jsonBody(request)["body"] as? String)
        #expect(body.count <= 60_000)
        let bodyLines = body.components(separatedBy: "\n")
        #expect(Array(bodyLines.prefix(4)) == header)
        let marker = try #require(bodyLines.dropFirst(4).first)
        let prefix = "…（古い行 "
        let suffix = " 行を省略）"
        #expect(marker.hasPrefix(prefix) && marker.hasSuffix(suffix))
        let omitted = try #require(Int(marker.dropFirst(prefix.count).dropLast(suffix.count)))
        let kept = bodyLines.count - 5
        #expect(omitted > 0)
        #expect(omitted + kept == lines.count)
        #expect(bodyLines.last == lines.last)
        #expect(bodyLines[5] == lines[omitted])
    }

    @Test func shortLogIsSentUnchanged() async throws {
        let log = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        _ = await upload([created()], log: log)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(try jsonBody(request)["body"] as? String == log)
    }

    @Test func invalidRepositoryNeverHitsNetwork() async {
        let session = StubURLProtocol.session(replying: [created()])
        let result = await MeasurementUploader(session: session).upload(
            log: "x", title: "t", repository: "owner/../x", token: token)

        #expect(result == .failed(.invalidRepository))
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func failureTextsAreFixedAndNeverContainToken() {
        let failures: [UploadFailure] = [
            .invalidRepository, .unauthorized, .notFound, .rateLimited, .network, .server(500), .badResponse,
        ]
        for failure in failures {
            #expect(!failure.userMessage.isEmpty)
            #expect(!failure.userMessage.contains(token))
        }
        #expect(UploadFailure.server(503).userMessage == "サーバーエラー（HTTP 503）")
        #expect(UploadFailure.unauthorized.userMessage == "トークンが無効か、権限がありません")
    }
}
