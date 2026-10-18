import Foundation

/// State machine behind the "share to LINE" button.
/// There is deliberately no "sent" state: opening LINE's share screen never
/// proves a message was sent (AT-07).
public struct ShareFlow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case confirming(text: String)
        case opened
        case failed(String)
        case cancelled
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func request(_ text: String) {
        // RED stub
        state = .idle
    }

    public mutating func cancel() {
        // RED stub
        state = .idle
    }

    public mutating func confirm() -> URL? {
        // RED stub
        nil
    }

    public mutating func didOpen(_ accepted: Bool) {
        // RED stub
    }

    public static func statusMessage(for state: State) -> String? {
        // RED stub
        nil
    }
}
