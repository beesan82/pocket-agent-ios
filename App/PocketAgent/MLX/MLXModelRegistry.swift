import Foundation

/// A downloadable MLX model (Hugging Face repo).
struct MLXModelInfo: Identifiable, Sendable, Equatable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen2.5-1.5B-Instruct-4bit".
    let id: String
    let displayName: String
    let revision: String
    /// Approximate total download size (all files, checked on Hugging Face 2026-10-18; Qwen3 4B on 2026-10-28).
    let approxBytes: Int64
    let license: String
    let notes: String
}

enum MLXModelRegistry {
    static let qwen25_1_5B = MLXModelInfo(
        id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        displayName: "Qwen2.5 1.5B Instruct（4bit）",
        revision: "main",
        approxBytes: 880_172_064,
        license: "Apache-2.0",
        notes: "既定モデル。")

    static let qwen3_1_7B = MLXModelInfo(
        id: "mlx-community/Qwen3-1.7B-4bit",
        displayName: "Qwen3 1.7B（4bit）",
        revision: "main",
        approxBytes: 984_015_687,
        license: "Apache-2.0",
        notes: "thinking 無効化が未確認のため候補のみ。")

    static let qwen3_4B = MLXModelInfo(
        id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
        displayName: "Qwen3 4B Instruct 2507（4bit）",
        revision: "main",
        approxBytes: 2_278_972_236,
        license: "Apache-2.0",
        notes: "上位候補（thinking なし）。iPhone 15 で速度・メモリ未測定（ADR-042）。")

    static let `default` = qwen25_1_5B
    static let all: [MLXModelInfo] = [qwen25_1_5B, qwen3_1_7B, qwen3_4B]

    static func model(id: String) -> MLXModelInfo? {
        all.first { $0.id == id }
    }
}
