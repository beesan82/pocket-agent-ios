import Foundation

enum UploadFailure: Equatable {
    case invalidRepository, repositoryNotPrivate, unauthorized, notFound, rateLimited, network, server(Int), badResponse

    /// Fixed texts only; neither the token nor any response body is ever included.
    var userMessage: String {
        switch self {
        case .invalidRepository: "送信先リポジトリの形式が正しくありません（owner/name）"
        case .repositoryNotPrivate: "送信先が非公開リポジトリではないため送信しませんでした"
        case .unauthorized: "トークンが無効か、権限がありません"
        case .notFound: "リポジトリが見つかりません（非公開リポジトリと権限を確認してください）"
        case .rateLimited: "送信回数の上限に達しました。しばらく待ってください"
        case .network: "通信できませんでした"
        case let .server(code): "サーバーエラー（HTTP \(code)）"
        case .badResponse: "応答を読み取れませんでした"
        }
    }
}

enum UploadResult: Equatable {
    case created(issueNumber: Int)
    case failed(UploadFailure)
}

/// Posts the measurement log as an Issue of the user's private GitHub repository.
/// The token only goes into the Authorization header; nothing of the response except the issue number is kept.
struct MeasurementUploader: Sendable {
    static let maxBodyCharacters = 60_000
    private static let headerLineCount = 4

    private struct IssuePayload: Encodable {
        let title: String
        let body: String
        let labels: [String]?
    }

    private struct IssueResponse: Decodable {
        let number: Int?
    }

    private struct RepositoryResponse: Decodable {
        let isPrivate: Bool?

        enum CodingKeys: String, CodingKey {
            case isPrivate = "private"
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(log: String, title: String, repository: String, token: String) async -> UploadResult {
        guard DeveloperSettings.isValidRepository(repository),
              let repositoryURL = URL(string: "https://api.github.com/repos/\(repository)"),
              let url = URL(string: "https://api.github.com/repos/\(repository)/issues")
        else { return .failed(.invalidRepository) }

        // The log contains spoken text: refuse unless GitHub itself says the repository is private.
        if let refusal = await checkPrivate(repositoryURL: repositoryURL, token: token) {
            return .failed(refusal)
        }

        let body = Self.truncated(log)
        var labels: [String]? = ["measurement"]
        while true {
            let payload = IssuePayload(title: title, body: body, labels: labels)
            guard let data = try? JSONEncoder().encode(payload) else { return .failed(.badResponse) }
            var request = Self.request(url: url, method: "POST", token: token)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data

            let responseData: Data
            let response: URLResponse
            do {
                (responseData, response) = try await session.data(for: request)
            } catch {
                return .failed(.network)
            }
            guard let http = response as? HTTPURLResponse else { return .failed(.badResponse) }
            // An unknown label makes GitHub answer 422: retry once without labels.
            if http.statusCode == 422, labels != nil {
                labels = nil
                continue
            }
            return Self.result(for: http, data: responseData)
        }
    }

    private static func request(url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// nil when the repository is confirmed private; otherwise the failure to report (no POST then).
    private func checkPrivate(repositoryURL: URL, token: String) async -> UploadFailure? {
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(
                for: Self.request(url: repositoryURL, method: "GET", token: token))
        } catch {
            return .network
        }
        guard let http = response as? HTTPURLResponse else { return .badResponse }
        guard http.statusCode == 200 else { return Self.failure(for: http) }
        guard let isPrivate = (try? JSONDecoder().decode(RepositoryResponse.self, from: responseData))?.isPrivate
        else { return .badResponse }
        return isPrivate ? nil : .repositoryNotPrivate
    }

    private static func failure(for http: HTTPURLResponse) -> UploadFailure {
        switch http.statusCode {
        case 401: .unauthorized
        case 403: http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" ? .rateLimited : .unauthorized
        case 404: .notFound
        case 429: .rateLimited
        default: .server(http.statusCode)
        }
    }

    private static func result(for http: HTTPURLResponse, data: Data) -> UploadResult {
        switch http.statusCode {
        case 201:
            guard let number = (try? JSONDecoder().decode(IssueResponse.self, from: data))?.number else {
                return .failed(.badResponse)
            }
            return .created(issueNumber: number)
        default:
            return .failed(failure(for: http))
        }
    }

    /// Keeps the header (first 4 lines) and the newest lines that fit; the omitted count is stated.
    static func truncated(_ log: String) -> String {
        guard log.count > maxBodyCharacters else { return log }
        let lines = log.components(separatedBy: "\n")
        let header = Array(lines.prefix(headerLineCount))
        let rest = Array(lines.dropFirst(headerLineCount))
        // Reserve room for the marker line (its number has at most 7 digits) and the joining newlines.
        let marker = { (omitted: Int) in "…（古い行 \(omitted) 行を省略）" }
        var budget = maxBodyCharacters - header.reduce(0) { $0 + $1.count + 1 } - marker(9_999_999).count - 1
        var keptCount = 0
        for line in rest.reversed() {
            let cost = line.count + 1
            if cost > budget { break }
            budget -= cost
            keptCount += 1
        }
        let omitted = rest.count - keptCount
        return (header + [marker(omitted)] + rest.suffix(keptCount)).joined(separator: "\n")
    }
}
