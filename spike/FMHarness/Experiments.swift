import Foundation
import FoundationModels

/// Isolates why a 2nd MLX turn garbles / skips the tool (feedback ADbZQHomlI8E).
/// Each trial uses a fresh session and auto-approval; the summary is one short line.
enum Sampling: String, CaseIterable, Identifiable {
    case providerDefault = "既定（温度 0.6・足切りなし）"
    case greedy = "greedy（毎回同じ）"
    var id: String { rawValue }
    var short: String { self == .greedy ? "g" : "既" }

    var options: GenerationOptions {
        switch self {
        case .providerDefault: GenerationOptions()
        case .greedy: GenerationOptions(sampling: .greedy)
        }
    }
}

enum Experiment: String, CaseIterable, Identifiable {
    case single = "A: 1ターン目に「牛乳を覚えておいて」"
    case afterChat = "B: 雑談の後の2ターン目"
    case afterTool = "C: ツール保存の後の2ターン目"
    case foldChat = "D1: 雑談を文字で畳み込んだ新セッション"
    case foldTool = "D2: ツール保存を文字で畳み込んだ新セッション"
    var id: String { rawValue }
    var short: String { String(rawValue.prefix { $0 != ":" }) }

    /// Turn sent before the measured one (nil = measured turn is the first).
    var warmup: String? {
        switch self {
        case .single: nil
        case .afterChat, .foldChat: "こんにちは。今日はいい天気ですね。"
        case .afterTool, .foldTool: "私の名前はケイタ 覚えておいて"
        }
    }

    /// D: the warmup runs in its own session; the measured turn gets a fresh session whose
    /// prompt carries the earlier exchange as plain text (like Pocket Agent's Apple-local fold).
    var folds: Bool { self == .foldChat || self == .foldTool }

    static let measuredPrompt = "牛乳を覚えておいて"

    static func folded(user: String, assistant: String, current: String) -> String {
        """
        これまでの会話（参考。ここに書かれた操作は実行済みとは限らない）:
        ユーザー: \(user)
        アシスタント: \(assistant)

        今回のユーザーの発言: \(current)
        """
    }
}

func toolCallCount(_ session: LanguageModelSession) -> Int {
    var count = 0
    for entry in session.transcript {
        if case .toolCalls(let calls) = entry { count += calls.count }
    }
    return count
}

/// Runs `trials` fresh sessions and logs how often the measured turn called save_note.
@MainActor
func runExperiment(
    _ experiment: Experiment, sampling: Sampling, trials: Int, backend: Backend,
    makeTools: () -> [any FoundationModels.Tool], clientID: String, log: SpikeLog
) async {
    var called = 0
    var finished = 0
    var warmupCalled = 0  // C / D2: the 1st turn's save_note succeeded
    var faked = 0  // reply says 保存 without a tool call
    var textCalls = 0  // the call was written into the reply text instead of a real tool call
    log.add("実験 \(experiment.rawValue) / \(sampling.rawValue) / \(backend.rawValue) × \(trials)")
    for trial in 1...trials {
        if Task.isCancelled { break }
        do {
            var session = try makeSession(backend, tools: makeTools(), clientID: clientID)
            var prompt = Experiment.measuredPrompt
            if let warmup = experiment.warmup {
                let first = try await session.respond(to: warmup, options: sampling.options)
                if toolCallCount(session) > 0 { warmupCalled += 1 }
                log.add("  #\(trial) 1ターン目 ← \(first.content)")
                if experiment.folds {
                    session = try makeSession(backend, tools: makeTools(), clientID: clientID)
                    prompt = Experiment.folded(user: warmup, assistant: first.content, current: prompt)
                }
            }
            let before = toolCallCount(session)
            let started = Date()
            let reply = try await session.respond(to: prompt, options: sampling.options)
            let didCall = toolCallCount(session) > before
            if didCall {
                called += 1
            } else {
                if reply.content.contains("保存") { faked += 1 }
                if reply.content.contains("save_note") || reply.content.contains("(\"") { textCalls += 1 }
            }
            finished += 1
            log.add(String(format: "  #%d 測定ターン %.1fs tool=%@ ← %@", trial,
                           Date().timeIntervalSince(started), didCall ? "yes" : "NO", reply.content))
        } catch {
            log.add("  #\(trial) error: \(String(reflecting: error))")
        }
    }
    // e.g. "C既 呼0/5 偽2 文1 初3"
    // 呼 = tool called, 偽 = claims saved without calling, 文 = call written as text,
    // 初 = (C / D2) 1st-turn save succeeded
    var line = "\(experiment.short)\(sampling.short) 呼\(called)/\(finished) 偽\(faked) 文\(textCalls)"
    if experiment == .afterTool || experiment == .foldTool { line += " 初\(warmupCalled)" }
    log.addSummary(line)
}
