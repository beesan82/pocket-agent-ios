import Foundation
import FoundationModels

/// The one app-defined tool every backend gets (spike items 1–4). Waits for the user's
/// approval inside `call`, since Foundation Models runs tools without a pre-execution hook.
struct SaveNoteTool: Tool {
    let name = "save_note"
    let description = "ユーザーが「覚えておいて」と頼んだ内容を端末内のメモに 1 件保存する。保存の前にユーザーの承認が必要。"

    @Generable
    struct Arguments {
        @Guide(description: "保存するメモの本文")
        var text: String
    }

    let approvals: ApprovalCenter
    let notes: NoteBox
    let log: SpikeLog

    func call(arguments: Arguments) async throws -> String {
        let started = Date()
        await log.add("Tool.call save_note text=\(arguments.text)")
        let approved = await approvals.ask(toolName: name, summary: arguments.text)
        let waited = String(format: "%.1f", Date().timeIntervalSince(started))
        if Task.isCancelled {
            await log.add("Tool.call cancelled after \(waited)s (approved=\(approved))")
            throw CancellationError()
        }
        guard approved else {
            await log.add("Tool.call rejected after \(waited)s")
            return "ユーザーが保存を拒否しました。保存されていません。"
        }
        await notes.append(arguments.text)
        await log.add("Tool.call approved after \(waited)s → saved")
        return "メモを保存しました: \(arguments.text)"
    }
}
