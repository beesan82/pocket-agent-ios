import ClaudeForFoundationModels
import Foundation
import FoundationModels
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

enum Backend: String, CaseIterable, Identifiable {
    case claudeAPIKey = "Claude (.apiKey)"
    case claudeAppAttest = "Claude (.appAttest)"
    case system = "SystemLanguageModel"
    case mlx = "MLX Qwen2.5 1.5B"

    var id: String { rawValue }
}

enum BackendError: Error, CustomStringConvertible {
    case noAPIKey, noClientID, mlxOnSimulator
    var description: String {
        switch self {
        case .noAPIKey: "Keychain に API キーがありません（Pocket Agent の設定で保存するか、下で保存）"
        case .noClientID: "App Attest の client ID が未入力です"
        case .mlxOnSimulator: "MLX はシミュレータでは動きません"
        }
    }
}

/// Same model as Phase 2-0's default (ADR-024), so memory numbers are comparable.
let mlxModel = #huggingFaceLanguageModel(
    configuration: LLMRegistry.qwen2_5_1_5b,
    capabilities: [.toolCalling])

let instructions = """
    あなたは日本語で答えるアシスタントです。ユーザーが「覚えておいて」と頼んだら save_note ツールを呼んで保存してください。\
    ツールを呼ばずに保存したと言ってはいけません。
    """

func claudeModel(auth: AuthMode) -> ClaudeLanguageModel {
    ClaudeLanguageModel(name: .haiku5_5, auth: auth)
}

/// One `LanguageModelSession` per backend; kept across sends so the transcript carries
/// multiple turns (spike item 4).
func makeSession(_ backend: Backend, tools: [any Tool], clientID: String) throws -> LanguageModelSession {
    switch backend {
    case .claudeAPIKey:
        guard let key = SpikeKeychain.readAPIKey(), !key.isEmpty else { throw BackendError.noAPIKey }
        return session(claudeModel(auth: .apiKey(key)), tools: tools)
    case .claudeAppAttest:
        guard !clientID.isEmpty else { throw BackendError.noClientID }
        return session(claudeModel(auth: .appAttest(clientID: clientID)), tools: tools)
    case .system:
        return session(SystemLanguageModel.default, tools: tools)
    case .mlx:
        #if targetEnvironment(simulator)
        throw BackendError.mlxOnSimulator
        #else
        return session(mlxModel, tools: tools)
        #endif
    }
}

private func session<M: LanguageModel>(_ model: M, tools: [any Tool]) -> LanguageModelSession {
    LanguageModelSession(model: model, tools: tools, instructions: instructions)
}

/// What the transcript holds: entry count and tool calls by name.
func transcriptSummary(_ session: LanguageModelSession) -> String {
    var entries = 0
    var toolCalls: [String] = []
    for entry in session.transcript {
        entries += 1
        if case .toolCalls(let calls) = entry {
            toolCalls += calls.map(\.toolName)
        }
    }
    return "transcript entries=\(entries) toolCalls=\(toolCalls)"
}
