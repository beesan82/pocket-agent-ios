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
Packages/PocketAgentRuntime (AgentRunKit フォーク 6.1.0-pocket.1 に依存、ADR-036)
  ├─ AgentRunner   : Agent を包み、承認必須・セッション承認の格下げ・キャンセル変換を強制
  └─ Tests         : ScriptedLLMClient（FakeLLM）で AT-05/08/09 を検証
        │
        ▼
App/PocketAgent/Adapters (AgentRunKit / Apple SDK 依存はここに閉じ込める)
  ├─ ClaudeAdapter       → AgentRunKit.AnthropicClient（Claude Messages API）
  ├─ OnDevice/           → Foundation Models `LanguageModelSession`（SystemLanguageModel / MLXLanguageModel、ADR-037）
  ├─ KeychainCredentialStore
  └─ SwiftDataHistoryRepository
```

### 分離の意図
- **PocketAgentCore は AgentRunKit に依存しない**。AgentRunKit の API 変更（要件13章: 影響高）を Adapter 層だけで吸収する。
- Core は Foundation のみを使うため、Mac がなくても Windows/Linux の Swift ツールチェーンで単体テストを回せる可能性がある（未検証。CI では macOS 上で `swift test` を実行）。
- UI → Core の Port（protocol）経由で Adapter を DI し、FakeLLM に差し替えてテストする（要件14章-3, 4）。

## 2. 依存ライブラリ（Phase 0 時点）

現在は AgentRunKit を MLX なしのフォーク `beesan82/AgentRunKit` の `6.1.0-pocket.1`（exact）に固定し、MLX は mlx-swift-lm 3.32.3 の MLXFoundationModels を使う（ADR-036）。CI ビルドは稼働中。正確な版は `App/Package.resolved` を見ること。下の表は Phase 0 時点の記録。

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
├─ AGENTS.md                    作業の決まり（CI、TDD、push の扱い）
├─ CLAUDE.md                    開発ガイド（制約・報告形式）
├─ README.md                    現在の状態と開発の流れ
├─ project.yml                  XcodeGen 定義
├─ codemagic.yaml               TestFlight 配信（手動起動）
├─ App/
│  ├─ Package.resolved          アプリ全体の依存の版（CI が版ずれを検査）
│  ├─ PocketAgent/              アプリ本体（SwiftUI）
│  │  ├─ PocketAgentApp.swift
│  │  ├─ Views/                 画面（チャット、記録タブ、承認シート、会議画面など）
│  │  ├─ Chat/                  ChatSession（1 会話の送信・停止・救済）、承認の仲介、音声入力
│  │  ├─ OnDevice/              端末内モデルの Foundation Models 経路（ターン実行、メモツールの橋渡し）
│  │  ├─ MLX/                   ダウンロードモデルの登録・取得・読み込み、測定ログ
│  │  ├─ Journal/               日誌の記録セッション、下書き、端末内モデルの選択
│  │  ├─ Meeting/               MeetingSession（会議の状態: セグメント・要点・保存。アプリで 1 つ）
│  │  ├─ Speech/                SpeechCapture（SpeechAnalyzer）、TranscriptSource、翻訳
│  │  ├─ Persistence/           SwiftData のスキーマ・移行、会話・メモ・日誌のストア
│  │  ├─ Settings/              モデルの選択
│  │  ├─ DevTools/              開発者モード、測定ログの送信
│  │  └─ Adapters/              AgentRunKit 依存コード（Claude クライアント、Keychain、可用性）
│  └─ PocketAgentTests/         アプリ側ユニットテスト（XCTest/Swift Testing）
├─ Packages/
│  ├─ PocketAgentCore/          純 Swift のドメイン（メモ、日誌、検索語、会議、ポリシー、LINE 共有 URL）
│  └─ PocketAgentRuntime/       AgentRunKit を使う層（ノートツール、承認ゲート、会話文脈、日誌検索、Claude アダプタ）
├─ ci/                          CI 補助スクリプト（Xcode 選択、秘密情報スキャン、シミュレータ選択）
├─ tools/                       TestFlight フィードバック取得（asc_feedback.py）
├─ docs/
│  ├─ architecture.md           本書
│  ├─ decisions.md              ADR
│  ├─ test-plan.md              AT-01〜AT-15 の検証方法と証跡
│  ├─ phase0-checklist.md       実装済み・実機未検証の一覧
│  ├─ testflight-setup.md       署名と配信の初回設定
│  ├─ verification/             実機での確認手順
│  ├─ handoff/                  別の開発環境への引き継ぎプロンプト
│  └─ superpowers/              設計書（specs）と実装計画（plans）
└─ .github/workflows/ios-ci.yml
```
