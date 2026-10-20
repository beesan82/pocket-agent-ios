# Architecture — Pocket Agent (仮称)

基準文書: `AGENT_REQUIREMENTS.md`（IOS-AGENT-REQ-001 v1.0）。本書はそこから導いた構成案であり、未検証の項目は「未検証」と明記する。

## 1. レイヤー構成

```text
App/PocketAgent (SwiftUI, iOS 26+)               ← UIのみ。ロジックを持たない
  ├─ Views: Chat / Approval / Settings / History
  └─ AppEnvironment (DI組み立て)
        │
        ▼
Packages/PocketAgentCore (純Swift, Foundationのみ)  ← Windows/Linuxでも `swift test` 可能を目標
  ├─ Domain        : ModelKind, ToolRisk, ToolRunState, AgentLimits …
  ├─ Tools         : LineShareURLBuilder, (PrepareLineMessage, SaveNote …)
  ├─ Policy        : PermissionPolicy（副作用ツール＝承認必須）
  └─ Ports         : ModelProvider, CredentialStore, HistoryRepository（protocol）
        │
        ▼
Packages/PocketAgentRuntime (AgentRunKit 6.1.0 に依存)
  ├─ AgentRunner   : Agent を包み、承認必須・セッション承認の格下げ・キャンセル変換を強制
  └─ Tests         : ScriptedLLMClient（FakeLLM）で AT-05/08/09 を検証
        │
        ▼
App/PocketAgent/Adapters (AgentRunKit / Apple SDK 依存はここに閉じ込める)
  ├─ ClaudeAdapter       → AgentRunKit.AnthropicClient（Claude Messages API）
  ├─ AppleLocalAdapter   → AgentRunKitFoundationModels.FoundationModelsClient
  ├─ MLXAdapter          → AgentRunKitMLX（Phase 2）
  ├─ KeychainCredentialStore
  └─ SwiftDataHistoryRepository
```

### 分離の意図
- **PocketAgentCore は AgentRunKit に依存しない**。AgentRunKit の API 変更（要件13章: 影響高）を Adapter 層だけで吸収する。
- Core は Foundation のみを使うため、Mac がなくても Windows/Linux の Swift ツールチェーンで単体テストを回せる可能性がある（未検証。CI では macOS 上で `swift test` を実行）。
- UI → Core の Port（protocol）経由で Adapter を DI し、FakeLLM に差し替えてテストする（要件14章-3, 4）。

## 2. 依存ライブラリ（Phase 0 時点）

| 依存 | 版 | 根拠 | 状態 |
|---|---|---|---|
| AgentRunKit | **exact 6.1.0**（tag `v6.1.0` = `a7ac823c`） | GitHub tags API で確認 | CIビルド未実施 |
| AgentRunKitFoundationModels | 同上（同一パッケージの product） | `Package.swift`@v6.1.0 で確認 | CIビルド未実施 |
| AgentRunKitMLX | 未リンク（Phase 2） | パッケージ解決時に mlx-swift-lm 2.30.x が取得される | — |

v6.1.0 のソースで確認した公開 API（Adapter 実装時の出発点。呼び出しコードは CI ビルドで検証してから書く）:
- `public struct AnthropicClient: LLMClient, ToolCallSurfacingClient, Sendable` — `public init(apiKey: String, model: String? = nil, maxTokens: Int = 8192, …) throws`、ヘッダ `x-api-key`、`anthropic-version: 2023-06-01`、`public static let anthropicBaseURL`。
- `public struct FoundationModelsClient<C: ToolContext>: LLMClient, Sendable` — `@available(iOS 26, macOS 26, *)`、`#if canImport(FoundationModels)`、`public init(tools: [any AnyTool<C>] = [], context: C, instructions: String? = nil)`。
- 承認関連は `Core/AgentLoop/ToolApproval.swift` に存在（中身は Phase 0-4 で読む）。
- テスト用に `AgentRunKitTesting.TestLLMClient` が存在。FakeLLM の実装候補。

## 3. ビルド・配信パイプライン

```text
Windows (Claude Code) ── git push ──▶ GitHub
                                      │
                                      ├─ GitHub Actions (xcode-27, Xcode 27.0)
                                      │    1. secret scan (AT-11 の最小版)
                                      │    2. swift test  Packages/PocketAgentCore
                                      │    3. xcodegen generate
                                      │    4. xcodebuild build (iOS Simulator, 署名なし)
                                      │    5. xcodebuild test  (iOS Simulator)
                                      │
                                      └─ Codemagic (Phase 1) 署名 → TestFlight
```

- `.xcodeproj` は Git 管理しない。`project.yml`（XcodeGen）を唯一の構成ソースにし、Windows から YAML 編集で保守する。
- 署名証明書・API キーはリポジトリにも CI ログにも置かない。

## 4. ディレクトリ構成

```text
AgentApp/
├─ AGENT_REQUIREMENTS.md        要件（唯一の基準）
├─ CLAUDE.md                    開発ガイド
├─ README.md                    実装済み/未実装/手動検証手順
├─ project.yml                  XcodeGen 定義
├─ App/
│  ├─ PocketAgent/              アプリ本体（SwiftUI）
│  │  ├─ PocketAgentApp.swift
│  │  ├─ Views/
│  │  └─ Adapters/              AgentRunKit 依存コード
│  └─ PocketAgentTests/         アプリ側ユニットテスト（XCTest/Swift Testing）
├─ Packages/
│  └─ PocketAgentCore/          純Swiftのドメイン・ツール・ポリシー
├─ ci/                          CI 補助スクリプト
├─ docs/
│  ├─ architecture.md           本書
│  ├─ decisions.md              ADR
│  ├─ test-plan.md              AT-01〜AT-15 の検証方法と証跡
│  └─ phase0-checklist.md
└─ .github/workflows/ios-ci.yml
```
