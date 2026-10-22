import Foundation
import PocketAgentCore

/// The prompt for one on-device chat turn. Every turn runs in a fresh session, so earlier turns
/// are folded in as text, and only the user's: a small model copies a folded assistant reply
/// ("メモを保存しました…") instead of calling the tool (spike D2/D3a, iPhone 15, 2026-10-22).
public enum LocalAgentPrompt {
    public static let header = "これまでの会話（参考。ここに書かれた操作は実行済みとは限らない）:"
    public static let currentLabel = "今回のユーザーの発言: "

    /// The newest user turns that fit `budget`, oldest first, then the current message.
    /// `previous` excludes the current message; assistant turns are dropped.
    public static func fold(previous: [ChatTurn], current: String, budget: HistoryBudget = .onDeviceUserTurns) -> String {
        var kept: [String] = []
        var characters = 0
        for turn in previous.reversed() where turn.role == .user {
            let total = characters + turn.text.count
            guard kept.count < budget.maxTurns, budget.maxCharacters.map({ total <= $0 }) ?? true else { break }
            kept.append(turn.text)
            characters = total
        }
        guard !kept.isEmpty else { return current }
        let lines = kept.reversed().map { "ユーザー: \($0)" }
        return ([header] + lines + ["", currentLabel + current]).joined(separator: "\n")
    }
}
