import PocketAgentCore
import PocketAgentRuntime

/// Fixed user-facing texts for runs that did not produce an answer.
/// Never built from an error value (ADR-010): use `LLMErrorDescriber` for thrown errors.
enum RunFailureText {
    static let stopped = "停止しました"
    static let emptyReply = "（空の応答）"

    static func message(for error: ModelResolutionError) -> String {
        switch error {
        case let .unavailable(reason):
            reason.userMessage
        case .credentialReadFailed:
            "APIキーを読み出せませんでした。設定画面で保存し直してください。"
        case .clientCreationFailed:
            "モデルを準備できませんでした。設定画面のモデルIDを確認してください。"
        }
    }

    /// `nil` for `.completed`, which is not a failure.
    static func message(for outcome: AgentRunOutcome) -> String? {
        switch outcome {
        case .completed:
            nil
        case let .endedEarly(reason, _):
            "途中で終了しました（\(reason)）"
        case let .stepLimitReached(limit):
            "上限（\(limit)ステップ）に達したため停止しました"
        case let .tokenBudgetExceeded(budget, used):
            "トークン上限を超えました（\(used)/\(budget)）"
        case .cancelled:
            stopped
        }
    }
}
