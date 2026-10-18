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
- [ ] 生成された `Package.resolved`（Artifact `ci-evidence`）をコミット
- [ ] CI ログから実際の Xcode / Swift / シミュレータ版を記録

## 0-3 AgentRunKit iOS ビルド
- [x] `AgentRunKit` と `AgentRunKitFoundationModels` をリンクし、ソースで存在を確認した型だけを参照（`SDKLinkCheck.swift`）
- [x] CI で上記がビルドでき、`SDKLinkCheckTests` が通ることを確認（commit `cc13b32`）

## 0-4 FakeLLM
- [x] `AgentRunKitTesting.TestLLMClient` の API をソースで確認 → 台本どおりの応答を返せないので不採用（ADR-007）
- [x] 自前 FakeLLM `ScriptedLLMClient` + `AgentRunner`（`Packages/PocketAgentRuntime`）
- [x] ツール呼び出し・承認拒否・セッション承認の格下げ・キャンセル・反復上限のテスト（AT-05, 08, 09 の土台）— CI run 39098564327 で 9/9 合格（`swift test`, macOS）
- [ ] アプリ全体（Xcode）のビルドに PocketAgentRuntime を含めて成功 — 同 run は Package.resolved の表示ステップで停止し未確認

## 0-5 モデル経路 1 往復
- [ ] ClaudeAdapter: 実 API キー（Keychain 入力）で 1 往復 — 実機
- [ ] AppleLocalAdapter: `SystemLanguageModel` の availability 判定 + 1 往復 — Apple Intelligence 対応実機
- [ ] 型付きツールを 1 件呼び出し

## ゲート / ブロッカー
- Apple Developer Program 契約・Bundle ID・TestFlight（実機検証に必須）
- Apple Intelligence 対応 iPhone の有無（要件15章で未確認）
- Anthropic API キー（ユーザーが端末上で入力。チャットやリポジトリに貼らない）
- AgentRunKit がビルド不能な場合: 「薄い独自 Agent Runtime + Apple Foundation Models」を代替案として提示し、**承認を得てから**切り替える
