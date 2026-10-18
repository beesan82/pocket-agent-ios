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
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .failed("共有する文面がありません")
        } else {
            state = .confirming(text: text)
        }
    }

    public mutating func cancel() {
        state = .cancelled
    }

    /// Returns the LINE share URL only while confirming; the state stays
    /// `.confirming` until the caller reports the open result via `didOpen`.
    public mutating func confirm() -> URL? {
        guard case .confirming(let text) = state else { return nil }
        do {
            return try LineShareURLBuilder.url(for: text)
        } catch {
            state = .failed("共有する文面がありません")
            return nil
        }
    }

    public mutating func didOpen(_ accepted: Bool) {
        guard case .confirming = state else { return }
        state = accepted ? .opened : .failed("LINEを開けませんでした")
    }

    public static func statusMessage(for state: State) -> String? {
        switch state {
        case .opened:
            return "LINEの共有画面を開きました（送信は未確認）"
        case .failed(let message):
            return message
        case .idle, .confirming, .cancelled:
            return nil
        }
    }
}
