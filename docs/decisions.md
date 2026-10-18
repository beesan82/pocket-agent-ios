# Decisions (ADR)

各項目: 決定 / 理由 / 影響要件 / 状態。

## ADR-001 プロジェクト生成に XcodeGen を採用
- 決定: `project.yml` から CI 上で `.xcodeproj` を生成し、`.xcodeproj` はコミットしない。
- 理由: Windows で pbxproj を手編集するのは事実上不可能。YAML なら差分レビューも容易（要件3.1「プロジェクト生成」）。
- リスク: CI の `brew install xcodegen` はバージョン非固定。問題が出たら mint 等でピン留めする。
- 状態: 採用（CI 未実行）

## ADR-002 AgentRunKit を exact 6.1.0 に固定
- 決定: `exactVersion: 6.1.0`。tag `v6.1.0` の commit は `a7ac823ca42d4ecff386a83c10a44a97bd391cdb`（2026-10-18 GitHub API で確認）。
- 理由: 要件13章「API変更／不安定さ」対策。`from:` では意図しない更新が入る。
- 状態: 採用（CI で Package.resolved を生成後、その内容をコミットして確定させる）

## ADR-003 ドメインを AgentRunKit 非依存の Swift Package に分離
- 決定: `Packages/PocketAgentCore` は Foundation のみに依存。AgentRunKit 呼び出しは `App/PocketAgent/Adapters` に限定。
- 理由: 要件3.3 設計原則、14章-3。SDK 交換時（代替案「薄い独自 Runtime」）の影響範囲を限定。
- 状態: 採用

## ADR-004 LINE 共有 URL は RFC 3986 unreserved 以外をすべて percent-encode
- 決定: `https://line.me/R/share?text=` の値を `A-Z a-z 0-9 - . _ ~` 以外すべてエンコードし、`URLComponents.percentEncodedQueryItems` に設定する。
- 理由: `URLComponents.queryItems` は `+` などをエンコードしないため、受信側で空白に化ける可能性がある（要件9.1、AT-06）。
- 状態: 実装済み・ユニットテストあり（CI 未実行）

## ADR-005 最低 OS は iOS 26.0
- 決定: deployment target iOS 26.0（要件3.2）。AgentRunKit 自体は iOS 18+ だが FoundationModelsClient は iOS 26+。
- 状態: 採用

## ADR-006 CI runner は `macos-26`、Xcode は 26.x の最新を選択
- 決定: runner image に同梱の `/Applications/Xcode_26*.app` から最新を `xcode-select` する。
- 理由: AgentRunKit v6.1.0 は Xcode 26+ 必須。runner の Xcode 構成は変わるため、ログに実際の版を出力して証跡にする。
- 状態: 採用（未実行。Xcode 26 が見つからなければ CI が明示的に失敗する）

## ADR-007 FakeLLM は自前の `ScriptedLLMClient`、安全ルールは `AgentRunner` に集約
- 決定: `AgentRunKitTesting.TestLLMClient` は使わず、`LLMClient` に準拠した台本再生型の FakeLLM をテスト側に置く。AgentRunKit の `Agent` は `Packages/PocketAgentRuntime` の `AgentRunner` で包む。
- 理由（v6.1.0 ソースで確認）:
  - `TestLLMClient` は渡されたツールを毎回全部呼ぶ作りで、「拒否後に終了」「同じツールを2回」などの台本を組めない。
  - `approvalPolicy != .none` で `approvalHandler` が nil だと precondition でクラッシュする → `AgentRunner` は常にハンドラを渡す。
  - `.approveAlways` はセッション中そのツールの承認を省略する → 外部副作用（LINE 共有）では `.approve` に格下げし、毎回確認する（要件7章「重複共有を抑止」）。
  - 反復上限は例外ではなく `FinishReason.maxIterationsReached` で返る。キャンセルは `CancellationError` として投げられる → `AgentRunOutcome.cancelled` に変換。
  - 終了は予約ツール `finish`（引数 `{"content": String, "reason": String?}`）。テキストのみの応答では終了しない（`ContentOnlyTerminatingClient` は package 内部のみ）。
- 影響要件: FR-04, FR-05, FR-06, AT-05, AT-08, AT-09
- 状態: 実装済み（CI 未実行）

## ADR-008 SDK のクライアントは包まずに `AgentRunner` へ渡す
- 決定: `ClaudeAdapter.makeClient` は `AnthropicClient` をそのまま返し、Apple は `FoundationModelsClient<EmptyContext>` をそのまま使う。選択の判断は Core の `ModelBackendResolver<Backend>`（AgentRunKit 非依存のジェネリック）に置く。
- 理由（v6.1.0 ソースで確認）: `Agent` はテキストのみの応答で終了するかを `client is any ContentOnlyTerminatingClient`（package 可視）で判定する。`AnthropicClient` と `FoundationModelsClient` は準拠済みだが、独自ラッパーは準拠できず、テキスト応答でも終了せず反復上限まで回る。
- 検証: `ClaudeAdapterTests.textReplyCompletesRunInOneRoundTrip`（URLProtocol スタブで実 `AnthropicClient` → `AgentRunner` が 1 回の HTTP で `.completed`）— CI run 39101123691 で合格。
- 影響要件: FR-01, FR-02, AT-01, AT-04
- 状態: 採用

## ADR-009 Apple ローカルには当面ツールを渡さない
- 決定: `FoundationModelsClient(tools:context:instructions:)` の `tools` は空で生成する。
- 理由（v6.1.0 ソースで確認）: `FoundationModelsClient` は渡されたツールを `FMToolAdapter` 経由で FoundationModels のセッション内から直接 `execute` する。`Agent` の `approvalPolicy` / 承認ハンドラを通らないため、外部副作用ツール（LINE 共有）を渡すと承認なしで実行され得る（FR-05 違反）。
- Phase 1 で Apple ローカルにツールを使わせる前に、ツール側で承認を待つラッパー等を設計し、FakeLLM 相当のテストを付ける。
- 影響要件: FR-05, AT-05
- 状態: 採用（暫定）

## ADR-010 APIキーは Keychain generic password（ThisDeviceOnly）
- 決定: `KeychainCredentialStore`（service `com.example.pocketagent.anthropic` / account `api-key`、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。保存は Update→なければ Add。エラーは `OSStatus` だけを持つ `KeychainError`。
- 理由: 要件 NFR「Keychain」。バックアップ・iCloud 同期に乗せない。エラー文言からキーが漏れない。
- 画面はキーを再表示しない（「保存済み」のみ）。モデル選択・モデル ID は秘密ではないので UserDefaults（`pocketagent.modelChoice` / `pocketagent.claudeModel`）。
- エラー表示は `LLMErrorDescriber` 経由のみ。AgentRunKit の `httpError` はレスポンス本文を含むため、`error` をそのまま画面やログに出さない。
- 影響要件: AT-01, AT-11
- 状態: 採用

## ADR-011 Claude の既定モデル ID は `claude-sonnet-5-5`
- 決定: 既定 `claude-sonnet-5-5`、`maxTokens` 1024。設定画面で変更可。
- 理由: 1往復検証の費用と速度のバランス（筆者の判断。ユーザー未確認）。
- 状態: 暫定

## ADR-012 CI の単体テストはシミュレータ向けアドホック署名で実行
- 決定: `xcodebuild test` のみ `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`（Sign to Run Locally）。`xcodebuild build` は無署名のまま。
- 理由: 無署名（`CODE_SIGNING_ALLOWED=NO`）では Keychain が `errSecMissingEntitlement`(-34018) を返した（run 39100885741）。アドホック署名で合格（run 39101123691）。証明書・Team ID・シークレットは不要。
- 状態: 採用

## 未決定
- 永続化: SwiftData 優先（要件15章）。Phase 1 冒頭で決定。
- Bundle ID / Team ID: 未定。現在はプレースホルダ `com.example.pocketagent`。
