import Foundation
import FoundationModels

/// Isolates why a 2nd MLX turn garbles / skips the tool (feedback ADbZQHomlI8E).
/// Each trial uses a fresh session and auto-approval; the summary is one log line.
enum Sampling: String, CaseIterable, Identifiable {
    case providerDefault = "既定（温度 0.6・足切りなし）"
    case greedy = "greedy（毎回同じ）"
    var id: String { rawValue }

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
    var id: String { rawValue }

    /// Turn sent before the measured one (nil = measured turn is the first).
    var warmup: String? {
        switch self {
        case .single: nil
        case .afterChat: "こんにちは。今日はいい天気ですね。"
        case .afterTool: "私の名前はケイタ 覚えておいて"
        }
    }

    static let measuredPrompt = "牛乳を覚えておいて"
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
    log.add("実験 \(experiment.rawValue) / \(sampling.rawValue) / \(backend.rawValue) × \(trials)")
    for trial in 1...trials {
        if Task.isCancelled { break }
        do {
            let session = try makeSession(backend, tools: makeTools(), clientID: clientID)
            if let warmup = experiment.warmup {
                let first = try await session.respond(to: warmup, options: sampling.options)
                log.add("  #\(trial) 1ターン目 ← \(first.content)")
            }
            let before = toolCallCount(session)
            let started = Date()
            let reply = try await session.respond(to: Experiment.measuredPrompt, options: sampling.options)
            let didCall = toolCallCount(session) > before
            if didCall { called += 1 }
            finished += 1
            log.add(String(format: "  #%d 測定ターン %.1fs tool=%@ ← %@", trial,
                           Date().timeIntervalSince(started), didCall ? "yes" : "NO", reply.content))
        } catch {
            log.add("  #\(trial) error: \(String(reflecting: error))")
        }
    }
    log.add("結果 \(experiment.rawValue) / \(sampling.rawValue): ツール呼び出し \(called)/\(finished)")
}
