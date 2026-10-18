import Foundation

enum UploadFailure: Equatable {
    case invalidRepository, unauthorized, notFound, rateLimited, network, server(Int), badResponse

    /// Fixed texts only; neither the token nor any response body is ever included.
    var userMessage: String { "" }
}

enum UploadResult: Equatable {
    case created(issueNumber: Int)
    case failed(UploadFailure)
}

/// Posts the measurement log as an Issue of the user's private GitHub repository.
struct MeasurementUploader: Sendable {
    static let maxBodyCharacters = 60_000

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(log: String, title: String, repository: String, token: String) async -> UploadResult {
        .failed(.network)
    }
}
