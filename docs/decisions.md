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
- 状態: 採用・確定。`Packages/PocketAgentRuntime/Package.resolved`（CI run 39101123691 の生成物、推移依存含む 10 件）をコミット。CI は生成した Xcode プロジェクトに同じファイルを置いてから解決し、ピンがずれたら失敗する（run 39101910024 で `pins match (10 packages)`）。

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
- 対策（実装済み）: `ToolApprovalGate.wrap(_:approval:)`（Runtime）が各ツールを `ApprovalGatedTool` で包み、`execute` の前で `AgentRunner` と同じ規則を適用する（読み取り専用以外は確認、外部副作用はセッション承認を格下げ、確認中のキャンセルは `CancellationError` でツール未実行）。セッション承認は `wrap` 呼び出し単位（会話単位）。
- Apple ローカルにツールを渡すときは必ず `ToolApprovalGate.wrap` の戻り値を使う。現時点でアプリはまだツールを渡していない。
- 検証: `ApprovalGatedToolTests` 8 件（CI run 39101910024）。FoundationModels セッション内からの実呼び出しは実機未検証。
- 影響要件: FR-05, AT-05, AT-08
- 状態: 採用

## ADR-010 APIキーは Keychain generic password（ThisDeviceOnly）
- 決定: `KeychainCredentialStore`（service `com.beesan82.pocketagent.anthropic`（2026-10-18 に Bundle ID 確定に合わせて変更。実機インストール前なので移行不要） / account `api-key`、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。保存は Update→なければ Add。エラーは `OSStatus` だけを持つ `KeychainError`。
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

## ADR-013 「この会話では許可」は ChatSession の寿命で有効（Runtime の `ConversationApprovals`）
- 決定: 会話単位の許可ストア `ConversationApprovals`（actor）でユーザーの `ApprovalHandler` を包み、`AgentRunner` と `ToolApprovalGate` の両経路に同じハンドラとして渡す。許可済みツールはダイアログなしで `.approveOnce` を返す。`delete_note`（`appInternalDelete`）と外部副作用ツールは許可を受け付けず毎回確認する。
- 理由: AgentRunKit 6.1.0 の `.approveAlways` は `run` 1 回ごとにリセットされる（`AgentLoopState.sessionAllowlist`、ソース確認済み）ため SDK には頼れない。
- 範囲の縮小（最終レビュー I3 への裁定）: 当初設計は「会話全体（再オープン・モデル切替をまたぐ）」だったが、実装は `ChatSession` が生きている間（チャット画面を開いている間）に限る。画面を離れると許可はリセットされ、再び聞かれる。モデル切替をまたぐ保持は `sessionApprovalSurvivesModelSwitch` で確認（チャット画面を開いたままの切替）。会話を開き直すたびの再確認が煩わしければ実機で見直す。
- 安全側: 範囲が狭いほど確認が増えるだけで、承認なしの副作用は増えない。ナビゲーション横断のレジストリを避けられる。
- 影響要件: FR-05, AT-05, AT-08
- 状態: 採用（Unit 合格・CI run 39114462235。実機未検証）

## ADR-014 メモツールは `ToolResult.error` を返し throw しない
- 決定: `save_note` / `list_notes` / `search_notes` / `delete_note` は、引数不正・ストア失敗・未知の id のいずれも `ToolResult.error` で返し、例外を投げない。
- 理由（v6.1.0 ソースで確認）: `FMToolAdapter` は `execute` の例外を再 throw し、FoundationModels のセッション全体が止まる。エラーはモデルへの結果として返すほうが会話を続けられる。
- 検証: `NoteToolsTests.invalidArgumentsNeverTouchStore` / `unknownIdIsReportedNotThrown` / `storeErrorsBecomeToolErrors`（CI run 39109697611、最終 39114462235）。
- 影響要件: FR-04, AT-05
- 状態: 採用

## ADR-015 逐次（ストリーミング）表示を後回し（FR-01 からの意図的な逸脱）
- 決定: Phase 1（プレーン版）では返答をまとめて表示する。
- 理由: 最小の土台で使い方を探すことを優先（設計「非ゴール」）。生成中は進行表示と停止ボタンのみ。
- 影響要件: FR-01（Must のため未達として扱う。次版で実装）
- 状態: 暫定（次版で解消）

## ADR-016 LINE 共有は画面のボタンのみ（ツールにしない）、AT-07 に「送信済み」状態は存在しない
- 決定: 共有は各アシスタント返答の「LINEで共有」ボタン → 確認ダイアログ → `LineShareURLBuilder` の URL を `openURL`。エージェントが共有を起動するツールは作らない。Core の `ShareFlow` に「送信済み」にあたる状態は持たず、表示は「LINEの共有画面を開きました（送信は未確認）」まで。
- 理由: 共有先選択画面を開くことと送信完了は別（CLAUDE.md）。貼り付け文に含まれる指示で共有が起動しない（要件9.1）。
- 検証: `ShareFlowTests.openedMessageNeverClaimsSent` / `confirmOnlyWhileConfirming` / `failedOpenIsReported` ほか（CI run 39108753238、最終 39114462235）。実機の画面遷移は未検証。
- 影響要件: FR-07, FR-08, US-01, AT-06, AT-07
- 状態: 採用

## ADR-017 Apple 端末内モデルは AgentRunKit 6.1.0 ではシングルターン。履歴は 1 つのプロンプトへ畳む
- 決定: Apple 経路は `ConversationContext.appleLocalPrompt(history:message:budget:)` で履歴を「これまでの会話: … / 今回のメッセージ: …」として 1 つの user メッセージに畳み、`history: []` で `run` する。システムプロンプトは唯一の `.system` メッセージとして渡し、貼り付けテキストは instructions に入れない（信頼できない入力）。Claude 経路は従来どおり構造化 history。
- 理由（v6.1.0 `FMMessageMapper.swift` で確認）: 先頭の `.system` と非空の `.user` ちょうど 1 件のみ許可され、`.assistant` / `.tool` は `featureUnsupported`。畳まないと 2 ターン目から失敗する。
- 経緯: 最終レビュー（C1）で発見。テストの fake（`FakeLLMClient.foundationModelsContract`）が mapper の制約を再現するようになった。
- 検証: `ConversationContextTests.appleLocalPrompt*`、`ChatSessionTests.appleLocalSecondTurnSendsOneFoldedPrompt`（CI run 39114462235）。実際の Foundation Models に対する複数ターンは実機未検証。
- 影響要件: FR-02, US-03, AT-02, AT-14
- 状態: 採用（実機未検証）

## ADR-018 RED/GREEN コミットを main へ直接 push（計画の一時ブランチ案からの逸脱）
- 決定: TDD の RED コミットと GREEN コミットをいずれも main へ直接 push し、RED は CI 実行の完了を待って失敗理由（アサーション失敗、コンパイルエラーでない）を確認した。
- 理由: ユーザーが main への push を事前承認済みで、CI は main への push でのみ自動実行される。一時ブランチ案はこの環境では手間が増える。
- 影響: RED の間 main の CI が一時的に赤くなる（各タスク約 2 回）。コミット履歴に RED が残る。
- 影響要件: プロセス（CLAUDE.md 開発順序 4）
- 状態: 採用

## ADR-019 会話履歴にはユーザーとアシスタントのテキストだけを保存（ツール結果は保存しない）
- 決定: `TurnRecord` は user / assistant のテキストのみ。ツール呼び出しと結果は保存せず、次ターンの履歴にも含めない。
- 理由: プレーン版で素朴に保つ。Apple 経路は履歴をテキストに畳むためツール結果を渡せない（ADR-017）。メモは `list_notes` で再取得できる。
- 影響: FR-10 の「ツール実行結果」の保存を、プレーン版では意図的に狭めた逸脱。
- 影響要件: FR-10, AT-10
- 状態: 暫定（使い方次第で見直し）

## 未決定
- 永続化: SwiftData を Phase 1 で採用（設計書）。
- Bundle ID: `com.beesan82.pocketagent`（2026-10-18 決定、ユーザー承認）。Team ID はリポジトリに書かず、Codemagic の自動署名がプロファイルから設定する。
