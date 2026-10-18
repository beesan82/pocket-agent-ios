import AgentRunKit
import Foundation

/// User-facing text for model failures (AT-01).
///
/// Never interpolates the error itself: AgentRunKit's `httpError` carries the raw
/// response body, which must not reach the screen or logs.
public enum LLMErrorDescriber {
    public static func userMessage(for error: any Error) -> String {
        guard case let AgentError.llmError(transport) = error else {
            return "応答を取得できませんでした。もう一度お試しください。"
        }
        switch transport {
        case let .httpError(statusCode, _) where statusCode == 401 || statusCode == 403:
            return "APIキーが無効か、権限がありません。設定画面でキーを確認してください。"
        case let .httpError(statusCode, _) where statusCode == 429:
            return "リクエストが混雑しています。しばらく待ってから再試行してください。"
        case .rateLimited:
            return "リクエストが混雑しています。しばらく待ってから再試行してください。"
        case let .httpError(statusCode, _):
            return "サーバーエラーが発生しました（HTTP \(statusCode)）。"
        case let .other(description) where description.contains("exceededContextWindowSize"):
            return "会話が長くなりすぎました。新しい会話を始めてください。"
        case .networkError:
            return "通信できませんでした。ネットワーク接続を確認してください。"
        default:
            return "モデルの応答を処理できませんでした。もう一度お試しください。"
        }
    }
}
