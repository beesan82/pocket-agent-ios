# Phase 0 チェックリスト（技術スパイク）

完了条件（要件12章）: **CIビルド成功・実機で2つのモデル経路を確認**。

凡例: [x] 完了（証跡あり） / [~] 実装済み・未検証 / [ ] 未着手

## 0-1 リポジトリ・設計
- [x] 要件書を全文確認
- [x] `docs/architecture.md` / `docs/decisions.md` / `docs/test-plan.md` 作成
- [x] AgentRunKit v6.1.0 の tag / Package.swift / 主要型シグネチャをソースで確認（ビルドではない）

## 0-2 プロジェクト・CI
- [x] XcodeGen `project.yml`（iOS 26, Swift 6, AgentRunKit exact 6.1.0）
- [x] 最小 SwiftUI アプリ（シミュレータ向けビルドのみ。実機未確認）
- [x] `PocketAgentCore` パッケージ + LINE URL ユニットテスト
- [x] GitHub Actions macOS CI（secret scan / swift test / xcodebuild build / test）
- [x] GitHub へ push（`beesan82/pocket-agent-ios`, commit `cc13b32`）
- [x] CI 初回成功（AT-12）— 2026-10-18、ユーザーが Actions 画面で確認。ログは未取得
- [x] 生成された `Package.resolved`（Artifact `ci-evidence`）をコミットし、アプリの解決にも使用・ずれ検知（run 39101910024）
- [x] CI ログから実際の Xcode / Swift 版を記録（Xcode 26.6 / Swift 6.3.3、runner macos-26）

## 0-3 AgentRunKit iOS ビルド
- [x] `AgentRunKit` と `AgentRunKitFoundationModels` をリンクし、ソースで存在を確認した型だけを参照（`SDKLinkCheck.swift`）
- [x] CI で上記がビルドでき、`SDKLinkCheckTests` が通ることを確認（commit `cc13b32`）

## 0-4 FakeLLM
- [x] `AgentRunKitTesting.TestLLMClient` の API をソースで確認 → 台本どおりの応答を返せないので不採用（ADR-007）
- [x] 自前 FakeLLM `ScriptedLLMClient` + `AgentRunner`（`Packages/PocketAgentRuntime`）
- [x] ツール呼び出し・承認拒否・セッション承認の格下げ・キャンセル・反復上限のテスト（AT-05, 08, 09 の土台）— CI run 39098564327 で 9/9 合格（`swift test`, macOS）
- [x] アプリ全体（Xcode）のビルドに PocketAgentRuntime を含めて成功 — run 39099104631（commit `8cbde12`）、Xcode 26.6 (17F113) / Swift 6.3.3。Core 8 + Runtime 9 + App 2 テスト合格

## 0-5 モデル経路 1 往復
設計: `docs/superpowers/specs/2026-10-18-phase0-5-model-adapters-design.md` / 計画: `docs/superpowers/plans/2026-10-18-phase0-5-model-adapters.md`

- [x] Core: `ModelChoice` / `ModelUnavailableReason` / `CredentialStore` / `ModelBackendResolver`（Apple 選択時はキーを読まず Claude を生成しない・フォールバックしない）— CI run 39101123691 で 17/17 合格
- [x] ClaudeAdapter（`AnthropicClient` を包まずに返す）+ `LLMErrorDescriber` — URLProtocol スタブ経由で `AgentRunner` 1 往復・`x-api-key` 送信・401 文言を確認（Runtime 16/16 合格、同 run）
- [x] `KeychainCredentialStore`（Security）保存・上書き・削除 — シミュレータで合格（同 run。アドホック署名が必要だった: 無署名では -34018、run 39100885741）
- [x] `AppleLocalAvailability`: `SystemLanguageModel.Availability` → 理由の写像 — シミュレータで合格（同 run）
- [x] 設定画面（キー入力・保存・削除、モデル選択、Apple 不可時は選択不可＋理由表示）と 1 往復テスト画面 — **ビルドのみ確認。画面操作は未検証**
- [ ] ClaudeAdapter: 実 API キー（Keychain 入力）で 1 往復 — **実機未検証**（TestFlight 未接続）
- [ ] AppleLocalAdapter: 実機での availability 判定 + 1 往復 — **実機未検証**（Apple Intelligence 対応実機が必要）
- [x] Apple ローカル向けツール承認ゲート `ToolApprovalGate`（ADR-009）— Runtime テスト 8 件合格（run 39101910024）
- [ ] 型付きツールを 1 件呼び出し（実モデル）— **実機未検証**。アプリにツール未接続

## ゲート / ブロッカー
- 実機検証の手順（TestFlight 接続後）: 設定でキー保存 → 1往復テスト（Claude）→ 設定で Appleローカル → 1往復テスト（機内モードでも応答すること、AT-02/AT-14）→ Claude に戻して再送信（AT-04）
- Apple Developer Program 契約・Bundle ID・TestFlight（実機検証に必須）
- Apple Intelligence 対応 iPhone の有無（要件15章で未確認）
- Anthropic API キー（ユーザーが端末上で入力。チャットやリポジトリに貼らない）
- AgentRunKit がビルド不能な場合: 「薄い独自 Agent Runtime + Apple Foundation Models」を代替案として提示し、**承認を得てから**切り替える
