# Phase 0-5 設計: モデル Adapter・Keychain・設定・1往復画面

日付: 2026-10-18 / 対象要件: FR-02, FR-03, NFR(Keychain), AT-01, AT-03, AT-04, AT-14（いずれも Unit 部分のみ。実機は未検証）

## 意図
Claude Messages API と Apple Foundation Models を設定で切り替え、同じ `AgentRunner` で 1 往復できる状態にする。
最重要の安全条件は2つ:
1. Apple ローカルを選んだら Claude 用の部品（APIキー読み出し・`AnthropicClient` 生成・HTTP 通信）が一切動かない（AT-14）。
2. Apple ローカルが使えないときは理由を表示して止まる。Claude へ黙って切り替えない（AT-03, FR-03）。

## 非ゴール
- チャット UI 本体・履歴・ストリーミング表示・LINE 共有ツール（Phase 1）。
- 実機検証（TestFlight 未接続のため「未検証」と記録する）。
- Apple ローカルでのツール呼び出し（後述の理由で Phase 0-5 では tools を渡さない）。

## アンチゴール（動いても失敗とみなす）
- APIキーがソース・UserDefaults・ログ・エラーメッセージ・CI に出る。
- Apple 非対応時に Claude で回答が返る。
- SDK クライアントを独自型で包み、AgentRunKit の終了判定が壊れる（下記「SDK 調査結果」）。

## SDK 調査結果（AgentRunKit 6.1.0 ソースで確認）
- `AnthropicClient.init(apiKey:model:maxTokens:...) throws`。`model` は `String?`。キーは `x-api-key` ヘッダにのみ入る。
- 非ストリーミング `Agent.run` は `generate` を使う。`HTTPRetry.performData` は 2xx 以外で `AgentError.llmError(.httpError(statusCode:body:))`、429 のみ `rateLimited`、通信失敗は `.networkError`。
- `shouldTerminateOnContent` は `client is any ContentOnlyTerminatingClient`（package 可視）で判定。`AnthropicClient` と `FoundationModelsClient` は準拠しているので、**テキストのみの応答で run が完了する**。独自ラッパーで包むとこの判定が外れ、テキスト応答では終わらず反復上限まで回る → **Adapter は SDK のクライアントをそのまま `any LLMClient` として渡す**。
- `FoundationModelsClient<C>(tools:context:instructions:)`（iOS 26+）は、渡された tools を `FMToolAdapter` 経由で FoundationModels セッション内から**直接実行**する。`AgentRunner` の承認ゲートを通らない → Phase 0-5 では tools を空にする。Phase 1 で Apple ローカルにツールを渡す前に承認付きラッパーを設計する（ADR に記録）。

## 構成（決定事項）
### Core（Foundation のみ、`swift test` で検証）
- `ModelChoice`: `.claude` / `.appleLocal`（`String` rawValue、UserDefaults 保存用。秘密ではない）。
- `ModelUnavailableReason`: `.missingAPIKey`, `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`, `.unsupportedOS`, `.unknown`。日本語の `userMessage` を持つ。
- `CredentialStore` プロトコル: `readAPIKey()`, `saveAPIKey(_:)`, `deleteAPIKey()`（throws）。
- `ModelAvailabilityChecking` プロトコル: Apple ローカルの可否を `ModelUnavailableReason?` で返す。
- `ModelBackendResolver<Backend>`: 選択・`CredentialStore`・可否判定・2つの生成クロージャから `Result<Backend, ModelResolutionError>` を返す。
  - `.appleLocal`: 可否判定のみ。使えなければ `.unavailable(reason)`。**キー読み出し・Claude 生成クロージャは呼ばない。**
  - `.claude`: キーを読み、空なら `.missingAPIKey`。あれば Claude 生成クロージャを呼ぶ。生成が throw したら `.clientCreationFailed`。
  - Core は AgentRunKit を知らないので `Backend` はジェネリック。

### Runtime（AgentRunKit 依存、`swift test` on macOS）
- `ClaudeAdapter.makeClient(apiKey:model:maxTokens:session:) throws -> AnthropicClient`。キーの trim、空なら throw。具体型を返す（包まない）。
- `LLMErrorDescriber.userMessage(for: Error) -> String`: 401/403 → キー無効、429 → 混雑、ネットワーク、その他。**レスポンス本文やキーを含めない。**
- テスト: `URLProtocol` スタブの `URLSession` を `AnthropicClient` に渡し、`AgentRunner` で 1 往復（テキスト応答で `.completed`）・`x-api-key` 送信・401 の文言（本文の内容が出ない）を確認。

### App（iOS 26、シミュレータの `xcodebuild test`）
- `KeychainCredentialStore`（Security, `kSecClassGenericPassword`, service = bundle id 系固定文字列, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。エラーは `OSStatus` のみ保持。
- `AppleLocalAvailability`: `SystemLanguageModel.default.availability` → `ModelUnavailableReason?` の写像（写像関数を単体テスト）。
- `ModelSettings`（`@Observable`）: 選択モデル・Claude モデル ID を UserDefaults に保存。キーは保存しない。
- `LLMClientFactory`: `ModelBackendResolver<any LLMClient>` を組み立てる。Apple は `FoundationModelsClient<EmptyContext>(context: EmptyContext())`、tools なし。
- 画面: `SettingsView`（キー入力 SecureField・保存・削除・保存済み表示は「保存済み」だけ、モデル Picker、Apple の可否と理由）、`RoundTripView`（プロンプト送信 → 結果／理由表示・停止ボタン）。`ContentView` からナビゲーション。

## 筆者の判断（要確認ポイント）
- Claude 既定モデル ID は `claude-sonnet-5-5`（設定画面で変更可）。`maxTokens` 1024。
- Keychain の単体テストは無署名シミュレータでエンタイトルメント不足（-34018）になる可能性がある。その場合はテストを既知の制約としてスキップし、実機で確認する旨を記録する。
- `ModelChoice` の既定値は `.claude`。
