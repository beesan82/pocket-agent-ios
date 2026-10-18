import Foundation

/// Builds the official LINE text-share URL (`https://line.me/R/share?text=...`).
///
/// Opening this URL only shows LINE's recipient picker. It never means the
/// message was sent (FR-08, AT-07).
public enum LineShareURLBuilder {
    public enum BuildError: Error, Equatable {
        case emptyText
    }

    /// RFC 3986 unreserved characters. Everything else (including `+`, `&`, `=`)
    /// is percent-encoded so LINE receives the text unchanged.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func url(for text: String) throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuildError.emptyText
        }
        // Encoding a valid Swift String with an ASCII allow-list cannot fail.
        let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved)!

        var components = URLComponents()
        components.scheme = "https"
        components.host = "line.me"
        components.path = "/R/share"
        components.percentEncodedQueryItems = [URLQueryItem(name: "text", value: encoded)]
        return components.url!
    }
}
