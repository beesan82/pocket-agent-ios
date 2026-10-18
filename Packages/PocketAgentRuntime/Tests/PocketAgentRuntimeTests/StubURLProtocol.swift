import Foundation

/// Intercepts every request of a session built by `StubURLProtocol.session()`.
/// No network. Tests using it must run `.serialized` because the stub is global.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        let url: URL?
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        let status: Int
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Response(status: 500, body: "")
    nonisolated(unsafe) private static var captured: [Captured] = []

    static func session(replying response: Response) -> URLSession {
        lock.withLock {
            self.response = response
            captured = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [Captured] {
        lock.withLock { captured }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.captured.append(Captured(
                url: request.url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.bodyData(of: request)
            ))
            return Self.response
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before protocols see it.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
