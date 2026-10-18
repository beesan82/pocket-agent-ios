import AgentRunKit
import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// Phase 0-5: one prompt → one answer through `AgentRunner`, for on-device verification.
/// The model is resolved at send time, so a settings change applies to the next send (AT-04).
struct RoundTripView: View {
    let settings: ModelSettings
    let credentials: any CredentialStore
    let availability: any ModelAvailabilityChecking

    private enum Phase: Equatable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    @State private var prompt = "こんにちは。一言で自己紹介してください。"
    @State private var phase = Phase.idle
    @State private var usedModel: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                TextField("メッセージ", text: $prompt, axis: .vertical)
                if phase == .running {
                    Button("停止", role: .destructive) { task?.cancel() }
                } else {
                    Button("送信") { send() }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text(settings.choice == .claude
                    ? "Claude選択中: 入力はAnthropic APIへ送信されます。"
                    : "Appleローカル選択中: 端末内で推論し、外部へ送信しません。")
            }

            Section("結果") {
                if let usedModel {
                    LabeledContent("モデル", value: usedModel)
                }
                switch phase {
                case .idle:
                    Text("未実行").foregroundStyle(.secondary)
                case .running:
                    ProgressView("生成中…")
                case let .finished(text):
                    Text(text).textSelection(.enabled)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("1往復テスト")
        .onDisappear { task?.cancel() }
    }

    private func send() {
        let resolver = LLMClientFactory.resolver(
            credentials: credentials, availability: availability, claudeModel: settings.claudeModel
        )
        let client: any LLMClient
        switch resolver.resolve(settings.choice) {
        case let .success(resolved):
            client = resolved
        case let .failure(error):
            usedModel = nil
            phase = .failed(Self.message(for: error))
            return
        }

        usedModel = settings.choice == .claude ? "Claude（\(settings.claudeModel)）" : "Appleローカル"
        phase = .running
        let runner = AgentRunner<EmptyContext>(client: client, tools: [], limits: AgentLimits(maxSteps: 2))
        let text = prompt
        task = Task {
            do {
                let outcome = try await runner.run(text, context: EmptyContext()) { _ in
                    .deny(reason: "No tools in the round-trip test")
                }
                phase = Self.phase(for: outcome)
            } catch {
                // Never show `error` itself: transport errors can carry response bodies.
                phase = .failed(LLMErrorDescriber.userMessage(for: error))
            }
        }
    }

    private static func phase(for outcome: AgentRunOutcome) -> Phase {
        switch outcome {
        case let .completed(text):
            .finished(text.isEmpty ? "（空の応答）" : text)
        case let .endedEarly(reason, _):
            .failed("途中で終了しました（\(reason)）")
        case let .stepLimitReached(limit):
            .failed("上限（\(limit)ステップ）に達したため停止しました")
        case let .tokenBudgetExceeded(budget, used):
            .failed("トークン上限を超えました（\(used)/\(budget)）")
        case .cancelled:
            .failed("停止しました")
        }
    }

    private static func message(for error: ModelResolutionError) -> String {
        switch error {
        case let .unavailable(reason):
            reason.userMessage
        case .credentialReadFailed:
            "APIキーを読み出せませんでした。設定画面で保存し直してください。"
        case .clientCreationFailed:
            "モデルを準備できませんでした。設定画面のモデルIDを確認してください。"
        }
    }
}
