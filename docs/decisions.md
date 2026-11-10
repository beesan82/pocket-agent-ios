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
- 状態: 採用・確定。`Packages/PocketAgentRuntime/Package.resolved`（CI run 39101123691 の生成物、推移依存含む 10 件）をコミット。CI は生成した Xcode プロジェクトに同じファイルを置いてから解決し、ピンがずれたら失敗する（run 39101910024 で `pins match (10 packages)`）。 → pin ファイルの場所は ADR-036 で `App/Package.resolved` に変更

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
- Apple ローカルにツールを渡すときは必ず `ToolApprovalGate.wrap` の戻り値を使う。チャットは Apple ローカルのクライアントへ、`ToolApprovalGate.wrap` で包んだ 5 つのメモツール（save_note / edit_note / list_notes / search_notes / delete_note）を渡している。承認シートで拒否された呼び出しも「試行」として記録される（ADR-028）。
- 検証: `ApprovalGatedToolTests` 8 件（CI run 39101910024）。FoundationModels セッション内からの実呼び出しは第1段階の TestFlight で確認予定（docs/verification/2026-10-19-apple-local-tools.md）。
- 影響要件: FR-05, AT-05, AT-08
- 状態: 採用 → 置き換え: ADR-037（端末内は FM セッション内のツールを `Tool.call` の中で承認）

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
- 状態: 採用（実機未検証） → 置き換え: ADR-037（毎ターン新しいセッション、ユーザー発言だけを畳み込む）

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

## ADR-027 保存済みメモと日誌を毎ターン注入
- 決定: 保存済みのメモと日誌を毎ターン会話へ注入する。Claude は system メッセージ、Apple ローカルはユーザープロンプトの「これまでの会話:」の前に置く。各項目は 1 行に平坦化する。Claude では保存済みメモと最近の日誌を毎ターン Anthropic へ送信し、チャット画面にその旨を表示する。
- 上限（`.claude`）: メモ 50 件 / 日誌 20 件×400 字 / 合計 12000 字。
- 上限（`.appleLocal`）: メモ 10 件×100 字 / 日誌 5 件×150 字 / 合計 1500 字。
- `edit_note` を追加。`list_notes` / `search_notes` は日誌も `kind` / `title` 付きで返す。日誌はチャットから編集・削除できない（貼り付け文経由の破壊を防ぐ）。
- 理由: モデルが `list_notes` を呼ばなくても「私の名前は？」に答えられるようにする。特に Apple ローカルはツールを呼べない場合がある。
- 検証: Core 76 / Runtime 83 / App 121 テスト。GREEN run は 39275624588（Task 1+2）、39279473804（Task 3）、39335923704（Task 4）、39340339947（Task 5+6）、39345177690（Task 7）。実機では未確認。
- 影響要件: FR-10, AT-05, AT-10
- 状態: 採用（実機未検証）

## ADR-028 本文中のツール呼び出し JSON の救済と「メモ非対応」表示
- 決定: ツールを呼べないモデルが返信本文に書いたツール呼び出し JSON を、アシスタントの返信だけから読み取って救済する。ユーザー入力に貼られた JSON は救済しない。
- 救済した呼び出しは読み取り専用を含めすべて承認シートを通す。拒否されたら返信は残し、何も保存しない。承認待ち中の停止では何も保存しない。
- `ToolCapabilityTracker` は、Claude 以外のモデルが救済 2 回、またはメモ意図のターンで呼び出しなし 2 回になったら「限定」と判定する。Claude 選択中は通知を出さない（抑止はトラッカーではなくアプリ側の `ChatSession` が行う）。
- 測定ログ: `toolcall.native|rescued|ambiguous|none model=<raw>[ tool=<name>]`。
- 理由: 小さなモデルはツール呼び出しを本文に書いてしまう。無視すると「保存した」と誤解させる。
- 検証: Unit のみ（CI run 39340339947, 39345177690）。実機では未確認。
- 影響要件: FR-05, AT-05, AT-08
- 状態: 採用（実機未検証）

## ADR-029 第1段階は iOS 26 のまま。iOS 27 化は Foundation Models スパイクで
- 決定: 第1段階（ADR-027, 028）は iOS 26 のまま TestFlight へ出す。iOS 27 化と 3 経路を同じ `Tool` で動かす検証は、第2段階の Foundation Models スパイク（`spike/fm-harness`）で行う。
- MLX へのツール配置は見送る。AgentRunKit 6.1.0 の `MLXClient` が `ContentOnlyTerminatingClient` ではないため。
- 理由: 実機の結果が出る前に基盤を変えない。スパイクは捨てる前提のコードにする。
- 検証: なし（方針）。
- 影響要件: FR-05, Phase 2
- 状態: 採用（実機未検証）

## ADR-030 対応 OS を iOS 27 に上げ、CI を Xcode 27.0（GitHub `xcode-27` ランナー）にする
- 決定: deploymentTarget を iOS 27.0 にする。GitHub Actions は `runs-on: xcode-27`（public preview）で、`ci/select-xcode.sh` が `Xcode_27.0.app` を選ぶ（`XCODE_PIN` で変更可）。同イメージは Metal Toolchain を同梱しないため（actions/runner-images#14548）、CI でも `xcodebuild -downloadComponent MetalToolchain` を実行する。
- 理由: Foundation Models の `LanguageModel` 差し替え（第2段階スパイク）が iOS 27 SDK を要する。ユーザーは iOS 27 への引き上げと iPhone 15 の更新を了承済み（2026-10-19）。macos-26 ランナーには Xcode 26.0〜26.6 しか無い（run 39434491253 で確認）。「最新」を選ぶと 27.2 beta が選ばれるため、リリース版の 27.0 に固定した。
- 検証: AgentRunKit 6.1.0・mlx-swift 0.30.6・mlx-swift-lm 2.30.6 が Xcode 27 でビルドでき、Core / Runtime / アプリのテストが iOS 27.0 シミュレータで合格（run 39434966799 は Xcode 27.2 beta、run 39437405259 は Xcode 27.0）。
- 影響要件: 6.1（対応 OS）、FR-13, Phase 2
- 状態: 採用（Codemagic の `xcode: latest` が Xcode 27 かどうか、iOS 27 下限のビルドが TestFlight で動くかは未検証）

## ADR-033 会議モードの要点は差分更新で、アプリが前面にある間だけ生成する
- 決定: 「会議」タブは端末内の文字起こし（SpeechAnalyzer）を発言単位のセグメント（録音開始からの秒 + 本文）で持ち、要点は「前回の要点 + 未反映の発言 → 要点の全文」の差分更新にする。自動更新は未反映 300 文字以上かつ前回更新開始から 60 秒以上（初回は文字数のみ）、アプリが前面にあり、モデルが使えて、更新中でないとき（`MeetingNotesPolicy`）。手動「更新」は未反映 1 文字以上。バックグラウンドでは端末内生成（Metal）が使えないため要点は止め（部分出力は捨てる）、前面復帰時に追いつく。失敗・停止時は前回の要点を保持し、未反映は減らさない。1 回の更新に載せる文字数はモデルの文脈予算（ADR-032 と同じ Apple 1500 字／ダウンロードモデル 3000 字、前回の要点を差し引く）までとし、ロック中にたまった分は前面復帰後に複数回に分けて追いつく。3 見出しが揃わない出力（トークン上限で途切れたもの）は採用せず前回の要点を保持する（max_tokens 1024）。終了時は未反映があれば最大 1 回更新してから、要点を本文・時刻付き全文を transcript・「会議 M/d HH:mm」を見出しとして日誌 1 件に保存する。要点が無ければ全文を本文として保存する（全文保存は常に可能）。モデルは ADR-032 の日誌の規則（Apple か ダウンロードモデル）に従い、Claude は使わない。
- 根拠: 1.5B モデルは 1 回 3〜12 秒（`docs/phase2-mlx-eval.md`）で、文字が増えるたびの全文再要約は追いつかない。差分更新なら入力長が会議の長さに依存しない。
- 検証: `MeetingTranscriptTests`、`MeetingNotesAssistantTests`、`MeetingSessionTests`（閾値・前面復帰・更新中の到着分・失敗時の保持・保存形式）。要点の品質・閾値は実機で使いながら調整する前提（初版）。
- 影響要件: FR-11, FR-14, FR-15, 6.3
- 状態: 採用（実機未検証）

## ADR-034 会議モードはバックグラウンド audio モードでロック中も録音・文字起こしを続ける
- 決定: `UIBackgroundModes` に `audio` を入れ、`AVAudioSession` を `.record` で有効にしたまま SpeechAnalyzer を回す。会議の状態（`MeetingSession`）はアプリが 1 つ保持し、タブ移動で消えない。電話などの割り込み（`AVAudioSession.interruptionNotification` の `.began`）では録音を止めて「録音が中断されました。再開してください。」と「再開」ボタンを出し、セグメントは保持する。`.ended` が `.shouldResume` 付きで来たら自動で録音を再開する（ロック中の通話で残りが失われないように）。`AVAudioSession` はアプリ内の全 `SpeechCapture` で共有なので、解放は最後の保持者が行う（日誌の音声入力を止めても会議は切れない）。
- 根拠: ユーザーの使い方（机に置かず、ポケットやロック状態のまま会議を聞かせる）。
- 検証: ロック中の継続・割り込み後の再開・1 時間連続は実機でしか確かめられない（`docs/phase0-checklist.md` 会議モード節）。
- 影響要件: FR-11, 9.2
- 状態: 採用（実機未検証）

## ADR-035 二言語の言語判定は「日英 2 系統の同時認識 + 発言ごとの信頼度比較」で、まず実機ゲートで測る
- 決定: SpeechAnalyzer に話し言葉の言語判定が無いため、同じマイク音声を日本語・英語の 2 つの `SpeechAnalyzer` に流し（`SpeechCapture(locales:)`）、確定結果を `transcriptionConfidence` の文字数加重平均付きの候補として Core の `LanguageArbiter` で判定する。候補は 1.5 秒保留し、時間範囲が重なる他系統の候補と 1 組にして信頼度の高い系統を採る（信頼度なしの系統は 0.5 扱い、同点は日本語側の文字種で決める）。判定済みと重なる遅着は捨て、出した発言は差し替えない。両系統 0.3 未満は雑音として出さない。翻訳は Apple Translation（端末内、導入済みペアは `TranslationSession(installedSource:target:)`、導入は `.translationTask` の同意シート）。会議画面への組み込み（段階 B）は、検証画面のゲート結果（`docs/bilingual-eval.md`）で閾値を確定してから。単一ロケールの `SpeechCapture` の動作は変えない。
- 根拠: 話者のタップ切替はユーザーが不可とした。2 系統の負荷と信頼度の分かれ方は実機でしか分からない。
- 検証: `LanguageArbiterTests`、`BilingualRunStatsTests`、`SpeechAvailabilityTests.reasonOrderWithEnglish`。実機は未検証。
- 影響要件: FR-11, 6.3
- 状態: 採用（段階 A。実機未検証）

## ADR-038 二言語会議（段階 B）を実機ゲートの前に組み込む。既定は OFF
- 決定: ユーザーの指示（2026-10-24「会議タブで二言語が使えるようにしたい」。会議タブで英語を話して崩れたフィードバック ABwK7YcC7U7h を受けて）により、段階 A の計測を待たずに会議タブへ組み込む。会議タブの「二言語（日本語・English）」トグル（`@AppStorage("meeting.bilingual")`、既定 OFF）が ON のときだけ 2 系統認識・判定・翻訳が動き、OFF なら従来と同じ。発言は `LanguageArbiter` で判定（0.5 秒ごと、一時停止・終了で drain、捕捉ごとに作り直し）し、相手の言語へ `AppleTranslator` で 1 件ずつ訳す。失敗は前面復帰と「更新」で再試行（最大 3 回）、「終了」は最長 10 秒待つ。要点の入力は日本語側。日誌の全文は原文と訳文の両方（`[mm:ss] (EN) 本文` と `    → 訳文`）。画面は 2 列（左: 日本語、右: English、原文セルは太字）。翻訳データは会議タブから同意シートで入手。
- 根拠: ユーザーの実機フィードバック（会議タブは日本語専用だったため英語が崩れ、訳も出なかった）。
- 検証: `BilingualMeetingTests`（判定後のセグメント化、到着順の翻訳、失敗と再試行、要点の日本語側、OFF で翻訳しない、終了時の drain と両テキストの保存、待ちの上限、再開時の判定器の作り直し）、`MeetingTranscriptTests`。実機は未検証（判定精度・負荷・翻訳の速さ・閾値は段階 A の計測と同じく未知）。
- 影響要件: FR-11, FR-14, 6.3
- 状態: 採用（実機未検証）

## ADR-039 会議の言語は「言語 1」「言語 2」の 2 つの選択で決め、中国語（普通話・簡体字）を加える
- 決定: ユーザーの指示（2026-10-24「中国語も対象に追加したい」「組み合わせ選択できるようにするのがベター」「選択肢は 2 つの項目で選ぶ」）。言語の一覧は Core の `MeetingLanguage.all`（日本語 ja_JP・English en_US・中文 zh_CN、表示名と全文の印 (EN)/(ZH)）の 1 か所で、言語を足すときはここに 1 行足す。会議タブは「言語 1」（既定 日本語）と「言語 2」（なし＋言語 1 以外、既定 なし）。なしなら単一言語（日本語以外も可）。日本語と中国語は漢字を共有するため、信頼度がないときの判定は「かながあれば日本語、漢字だけなら中国語」（`ScriptGuess.language(of:among:)`、`LanguageArbiter(languages:)`）。訳文は訳した言語を持ち、要点は日本語の原文か日本語訳だけを日本語として読む。日本語を含まない組み合わせでは原文のまま要点のモデルに渡す（要点は日本語）。音声の可否理由は言語ごとに一般化（日本語は従来の文言）。旧「二言語」スイッチ ON は初回に 言語 2 = English へ移行。繁体字は対象外。
- 検証: `MeetingTranscriptTests`（印・訳文の言語・表）、`LanguageArbiterTests.scriptGuessSeparatesJapaneseAndChinese` / `arbiterUsesItsLanguagesForScriptDecisions`、`SpeechAvailabilityTests.reasonOrderWithSeveralLanguages`、`BilingualMeetingTests`（English だけの会議、English・中文、日本語・中文の両方向翻訳、会議中の変更無視）。実機は未検証（zh-CN の音声認識と翻訳の対応、日中の判定精度）。
- 影響要件: FR-11, 6.3
- 状態: 採用（実機未検証）

## 未決定
- 永続化: SwiftData を Phase 1 で採用（設計書）。
- Bundle ID: `com.beesan82.pocketagent`（2026-10-18 決定、ユーザー承認）。Team ID はリポジトリに書かず、Codemagic の自動署名がプロファイルから設定する。

## ADR-020 MLX は generate/stream を直接呼び、AgentRunner を通さない
- 決定: 端末内 MLX（日誌の要約・質問回答）は `MLXClient` の `generate` / `stream` を直接呼ぶ。`AgentRunner` には載せない。
- 理由: `MLXClient` は `ContentOnlyTerminatingClient` ではなく、`AgentRunner` の終了判定に合わない。日誌は 1 回の要約／回答でツール往復が不要（設計書 Phase 2）。
- 影響要件: FR-15, AT-15
- 状態: 採用（実機の要約は 3/6/12 秒で動作確認、`docs/phase2-mlx-eval.md`。日誌画面からの生成は実機未検証）

## ADR-021 Phase 2 のプライバシー境界: 日誌は端末内のみ、Claude のノートツールは `.noteTool` だけを見る
- 決定: `.journal` 由来のエントリは端末内（MLX）でのみ扱う。Claude に渡るノートツール（`list_notes` / `search_notes` 等）は `JournalNoteStore` の射影で `origin == .noteTool` のエントリだけを見る。
- 理由: 録音の文字起こしを無断でクラウドへ送らない（CLAUDE.md、AT-14）。
- 検証: `JournalPersistenceTests.noteToolsSeeOnlyNoteToolEntries`、`noteProjectionAddsAsNoteTool`（CI run 39284990942 を含む緑のラン）。
- 後続の設計: 別セッションの設計（commit `f1a8a4b`、`8102472`「user decision」）は、`.journal` エントリを記憶の注入および list/search 経由で Claude へ送る意図を持つ。**この境界は Phase 2 時点の状態であり、その設計が実装された時点で置き換えられる**（実装されるまでは本 ADR が現行）。
- 影響要件: FR-15, AT-14
- 状態: 採用（Phase 2 時点。後続設計で置換予定） → 置き換え: ADR-040（日誌は Claude 選択時もチャットの文脈として送る。ユーザー判断 2026-10-24）

## ADR-022 質問は 2 段階: 日付範囲を母集合とし、語は絞り込みだけに使う
- 決定: 1 段目で相対日付（先週・一昨日など）を範囲に解決し、その範囲を母集合とする。検索語は母集合を絞り込むだけで、語で母集合を広げない。ヒットが無い場合は直近 10 件へフォールバックし、画面上でそれと分かる表示を付ける。
- 理由: 小型モデルの語抽出は不安定。範囲が確定していれば語の失敗が致命的にならない。フォールバックを明示して根拠のない回答を避ける。
- 影響要件: FR-15
- 状態: 採用（自動テストは Core 68 件に含む。実機での「先週」・キーワード・ヒット無しは未検証） → 「日誌に聞く」は廃止。同じ 2 段階をチャットの `JournalLookup` が毎ターン行う（ADR-040）

## ADR-023 モデルのダウンロード方針
- 決定: ダウンロードは画面のタップでのみ開始し、確認を出す。空き容量はモデルサイズの 1.5 倍を要求する（`DiskSpaceRule`）。ダウンロードはフォアグラウンドのみ、Wi-Fi 推奨を案内する。読み込みはローカルディレクトリ（`ModelConfiguration(directory:)`、Hub はオフラインモード）から行い、読み込み時にネットワークへ接続しない。
- 理由: 端末内推論の選択時に無断通信をしない（CLAUDE.md）。id 指定の読み込みは Hub へ再問い合わせし得るため退けた（Task 4 レビュー）。
- 影響要件: FR-15, AT-14, AT-15
- 状態: 採用（機内モードでの読み込みは実機未検証）

## ADR-024 既定モデルは Qwen2.5-1.5B-Instruct-4bit（実機ゲートの結果）
- 決定: 既定は `mlx-community/Qwen2.5-1.5B-Instruct-4bit`。
- 理由（iPhone 15、TestFlight ビルド 5、2026-10-19、`docs/phase2-mlx-eval.md` 測定 2）: 短文 3.0 秒 / 中文 6.0 秒 / 長文 12.0 秒、18〜30 tok/s、読み込み後 831 MB、メモリ警告なし、「見出し:」形式に従う。
- 見送り: Qwen3 1.7B（測定 1）は thinking 出力で maxTokens を使い切り 25〜30 秒・見出し欠落、測定中にメモリ警告。thinking 無効化を確認できるまで既定にしない（非既定の候補として残す）。
- 影響要件: FR-15, AT-15
- 状態: 採用（要約本文の品質は実使用で未確認）

## ADR-025 SwiftData を VersionedSchema V1→V2 にし、NoteRecord を一度だけ移行
- 決定: スキーマを `VersionedSchema` の V1→V2 とし、起動時に `NoteRecord` を日誌エントリへ一度だけ移行する。id は保持する。移行が途中で失敗しても再試行できるよう upsert する。「全データ削除」は移行後に残った `NoteRecord` も削除する。
- 理由: 既存メモを失わない。部分的に保存された後の再試行で重複させない。失敗した移行の残骸が全削除後も残るプライバシー上の穴を塞ぐ（最終レビュー I3）。
- 検証: `migrationCopiesAndDeletesOnce`（id 保持の検証を含む）、`migrationFailureKeepsNotes`、`migrationRetryAfterPartialSaveUpserts`、`eraseAllRemovesLeftoverNoteRecords`（CI run 39284990942）。
- 影響要件: FR-10, AT-10
- 状態: 採用（ビルド 5 のストアが V2 で開けたことは暗黙の確認のみ。既存メモありの実移行は実機未検証）

## ADR-026 デバッグ経路: 測定ログ、開発者モードの Issue 送信、TestFlight フィードバック
- 決定: (1) 測定ログをアプリ内で保持しコピー／共有できる（「全データ削除」で消える。バックアップ対象外）。(2) 開発者モードで、測定ログを非公開リポジトリの GitHub Issue へ送信できる。トークンは Keychain に保存し、送信前に対象リポジトリが private であることを API で確認して、そうでなければ拒否する。「全データ削除」でトークン削除と開発者モード解除も行う。(3) TestFlight のフィードバックは `tools/asc_feedback.py` で読む。App Store Connect の API キー（Developer ロール）はリポジトリの外に置く。
- 理由: Windows のみの環境で実機の結果を回収するため。ログには文字起こし本文を入れず、件数などの測定値のみとする。
- 影響要件: 要件の秘密情報の扱い（CLAUDE.md）、AT-11
- 状態: 採用（実際の GitHub API に対する送信、トークン権限、private 判定は実機未検証。Issue 送信は成功の確認なし）

## ADR-031 チャットのダウンロードモデル（`.mlxLocal`）はツールなしの会話のみ。既定モデルにする
- 決定: `ModelChoice.mlxLocal` を追加し、設定を「クラウド（Claude）／ローカル（端末内: Apple・ダウンロードモデル）」の階層にまとめる。`.mlxLocal` のチャットは resolver と AgentRunner を通らず、`LocalChat` が MLX クライアントへ直接ストリームする（AgentRunKit 6.1.0 の `MLXClient` は `ContentOnlyTerminatingClient` ではないため）。ツール・ToolCapabilityTracker・救済・`toolcall.*` ログは使わない。保存を頼まれたら日誌タブを案内する。resolver は `.mlxLocal` を担当外として `.modelNotDownloaded` で安全側に失敗させ、キーを読まずクライアントも作らない。既定のチャットモデルは `.mlxLocal`（ユーザー判断、2026-10-21）。一度だけの移行で、保存済みの選択が Claude または未設定の場合、API キーがあれば Claude を保存して維持し、なければ `.mlxLocal` にする（フラグ `pocketagent.defaultModelMigrated`）。未ダウンロードなら理由と設定へのリンクを出し、自動ダウンロードはしない。
- 停止・バックグラウンド・メモリ解放では途中の返答を保存しない。メモリ解放後のストリーム完了も保存しない（`reason() == .unloadedForMemory` で判定。1 回の返答中に解放→再読み込みされた場合は検出しない。発生しにくいので受け入れる）。ダウンロードの状態とダイアログはアプリで 1 つ（`ModelDownloadFlow`）を共有する。
- 理由: Claude API を使わない利用者（iPhone 15、Apple Intelligence 非対応）がチャットを使えるようにする。ツール対応は FM ハーネスの第 2 段階で置き換える可能性がある。
- 検証: Core `mlxLocalNeverReadsKeyOrBuildsClients`、Runtime `LocalChatTests`、App `ChatSessionLocalTests`（`mlxLocalNeverTouchesResolverOrKey`、`stopDoesNotSavePartial`、`unloadDuringStreamDoesNotSavePartial` ほか）、`ModelSettingsTests`（移行）。CI run 39476767480（App 148 件）。
- 影響要件: FR-02, FR-03, AT-03, AT-14
- 状態: 採用（設定の階層 UI、チャット往復、機内モード、停止、ダイアログ表示は実機未検証） → 置き換え: ADR-037（`.mlxLocal` もメモツール付き。`LocalChat` は削除）

## ADR-032 日誌タブは設定の端末内モデルに従う（Apple が使えれば Apple、それ以外はダウンロードモデル）
- 決定: 日誌の要約と「日誌に聞く」は、設定で Apple を選んでいてこの端末で使えるなら Apple（`FoundationModelsClient`、ツールなし）、それ以外（Claude 選択時、ダウンロードモデル選択時、Apple 不可の端末）はダウンロードモデルを使う（ユーザー判断、2026-10-22）。Claude は日誌に使わず、日誌の経路は API キーを読まない。判定は Core の `JournalModelRule`。Apple 選択で使えない場合は「Apple は使えないため、ダウンロードモデルを使います」と表示する。Apple は文脈が小さい（約 4096 トークン）ため、「日誌に聞く」に詰める日誌は Apple 1500 字、ダウンロードモデル 3000 字。要約の入力は切り詰めず、超過時は既存の固定の失敗文を出す。ADR-026 までの「日誌は常にダウンロードモデル」を置き換える。
- 検証: `JournalModelRuleTests`（4 規則＋可用性は Apple 選択時のみ確認）、`JournalAssistantTests.askUsesContextBudget`、`JournalModelAccessTests`（Apple は読み込みなしで準備完了、ダウンロードモデル経路は従来どおり）。CI run 39692758413（Core 87 / Runtime 96 / App 156）。
- 影響要件: FR-15, AT-14
- 状態: 採用（Apple での要約・質問は実機未検証: シミュレータでは動かず、iPhone 15 は Apple Intelligence 非対応。1500 字が文脈に収まるかも未確認） → Apple の日誌経路は ADR-037 の `FoundationModelsTextClient` に置き換え → 「日誌に聞く」部分は ADR-040 で廃止（要約と会議は従来どおり）

## ADR-036 AgentRunKit をフォーク（MLX なし）にし、mlx-swift-lm 3.32.3 の MLXFoundationModels を使う
- 決定: AgentRunKit は `https://github.com/beesan82/AgentRunKit` タグ `v6.1.0-pocket.1`（本家 6.1.0 から `AgentRunKitMLX` ターゲット・製品・テストと mlx-swift-lm 依存だけを外したもの）を exact で使う。端末内モデルは mlx-swift-lm 3.32.3（`MLXFoundationModels` / `MLXHuggingFace` / `MLXLLM` / `MLXLMCommon`）、mlx-swift 0.32.3、swift-huggingface 0.13.0（ダウンロード）、swift-transformers 1.3.5（tokenizer）で動かす。アプリの pin は `App/Package.resolved`（アプリ全体のグラフ）にコミットし、CI と Codemagic はこれを xcodeproj に複写して解決し、ずれたら失敗させる。Runtime パッケージ単体は AgentRunKit だけを解決するので、その `Package.resolved` は追跡しない。MLX のマクロ（`#huggingFaceTokenizerLoader`）のため、`xcodebuild` に `-skipMacroValidation -skipPackagePluginValidation`、Codemagic は `defaults write`（マクロ・プラグインの指紋確認を省く）と `--archive-flags="..."`。
- 理由: 本家 6.1.0 は mlx-swift-lm を `.upToNextMinor(from: "2.30.0")` で宣言しており、MLX 製品を使わなくても 3.32.3 と同じグラフに入らない（CI run 39808046945）。フォークなら解決できる（run 39863746172）。端末内は Foundation Models に移すので AgentRunKitMLX は不要（ユーザー判断、2026-10-23）。
- ダウンロード: `HubClient(cache: nil).downloadSnapshot(of:kind:to:revision:matching:progressHandler:)` で `AppSupport/Models/models/<repo id>` に直接置く（キャッシュを使うと 2 重に保存されるため）。旧 `HubApi.snapshot` と同じ場所なので、ダウンロード済みの端末は再ダウンロード不要（`downloaderDirectoryLayoutUnchanged`）。
- 戻し方: 本家が mlx-swift-lm 3.x に追従したら本家の版に戻す。
- 検証: CI run 40065168351（Core 94 / Runtime 104 / App 179、pin 一致 13 件、シミュレータ・実機ビルド）。
- 影響要件: ADR-002（pin 固定）、FR-15, Phase 2
- 状態: 採用（実機での読み込み・ダウンロードは未検証）

## ADR-037 端末内のチャット・日誌・会議は Foundation Models。端末内チャットは毎ターン新しいセッション＋greedy＋ユーザー発言だけ畳み込み、メモツールは両端末内モデルで承認付き
- 決定:
  - 端末内のモデルは `SystemLanguageModel.default`（Apple）と `MLXLanguageModel`（ダウンロードモデル、`capabilities: [.toolCalling]`、ローカルディレクトリからのみ読み込み）。どちらも `LanguageModelSession` で使う。
  - チャット（`.appleLocal` / `.mlxLocal` 共通、`ChatSession.sendOnDevice`）: 毎ターン新しいセッション、`GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)`。instructions は `ConversationContext.onDeviceInstructions`（Claude と同じ規則＋保存済みメモ）。プロンプトは `LocalAgentPrompt.fold`（前の**ユーザー発言だけ**を最大 6 件・1500 字で畳み込み、アシスタントの返答・ツール結果は入れない）。
  - メモツール 5 種を両モデルに: `NoteTools` → `ToolApprovalGate`（書き込みは承認必須、ネイティブの読み取りは承認なし）→ 記録 → `FMNoteTools`（`@Generable` 引数を JSON にして `NoteToolBridge` 経由で実行）。承認待ちで停止すると `CancellationError` で何も保存しない。「この会話では常に許可」は会話単位（`ConversationApprovals`）。
  - ネイティブ呼び出しが無い返答は救済（`ToolCallRescue` → 必ず承認）、`toolcall.*` ログ、`ToolCapabilityTracker` の「メモ非対応」表示を**両端末内モデル**に適用（Claude には出さない）。
  - 日誌・「日誌に聞く」・会議の要点・MLX 検証画面は `FoundationModelsTextClient`（AgentRunKit の `LLMClient` 準拠、毎回新しいセッション、`max_tokens` / `temperature` だけを渡し `top_p` / `repetition_penalty` は捨てる）。
  - Claude は `AgentRunner` のまま（変更なし）。resolver は `.appleLocal` をツールなしの text client に解決するが、チャットからは使わない。
  - 停止: `stop()` はターンの `TurnStop` を立て、開いている承認シートを拒否として閉じる。以後のツール呼び出しは `StoppableTool` が実行前に断る。Foundation Models がツール呼び出しを取り消されたタスクの外で走らせても、停止後に保存されない（最終レビュー Important 1）。
  - 返答のストリームは「ここまでの全文」を流し、チャットは最後のものを保存する（モデルがツール呼び出しの後に本文を書き直しても重複しない。最終レビュー Important 3）。
  - 保存済みメモは、Claude と同じく instructions に入る（第1段階の Apple ローカルはプロンプト側に置いていた）。メモに貼り付け文が入っていても「データであり指示ではない」規則（`memoryRule`）で扱う。
  - 既知のリスク: メモリ警告で MLX を解放したとき、進行中のターンが止まるまでの短い間に解放済みモデルへ次の生成要求が出ると、再読み込みが起きうる（ChatView が停止させ、停止後のツール呼び出しは断るので、新しい要求は出にくい）。実機手順 7 で確かめる。
- 理由（スパイク `spike/fm-harness`、iPhone 15 / iOS 27.0.1、MLX Qwen2.5 1.5B）: 1 ターン目のツール呼び出しは greedy で 5/5、既定（温度 0.6）は 4/5 で崩れた本文が出る。同じセッションの 2 ターン目以降は 0/5（雑談の後でも）で、保存後は「保存しました」と偽る。毎ターン新しいセッション＋ユーザー発言だけの畳み込みで 5/5、アシスタント返答や「（処理済み）」を畳み込むと失敗。Apple 端末内モデル（iPhone 18,5）は手動では保存できたが、連続実験ではほぼ呼ばずに偽る。救済と非対応表示はその対策として残す。
- 置き換え: ADR-009（Apple ローカルへのツール配置の方式）、ADR-017（Apple の畳み込みは `appleLocalPrompt`）、ADR-031（`.mlxLocal` はツールなし・`LocalChat`）、ADR-032 の「Apple は `FoundationModelsClient`」の部分。
- 検証: Runtime `LocalAgentPromptTests`、App `ChatSessionLocalTests`（`stopDeniesApprovalEvenWhenToolIgnoresCancellation`、`rewrittenReplyIsNotDuplicated`、`nativeSaveAsksAndSaves`・`stopWhileApprovalPendingSavesNothing`・`rescuedJSONAsksAndSaves`・`twoMissesMarkLimitedForBothLocalModels` を両モデルで、`secondTurnFoldsOnlyUserTurnsAndInjectsMemory`、`switchingFromClaudeFoldsOnlyUserTurns`、`onDeviceNeverReadsKey` ほか）、`NoteToolBridgeTests`、`OnDeviceGenerationTests`。CI run 40072643817（Core 110 / Runtime 92 / App 187、main 取り込み後）。
- 影響要件: FR-04, FR-05, FR-10, 6.4, AT-05, AT-08, AT-14
- 状態: 採用（実機未検証。手順: docs/verification/2026-10-24-stage2-on-device-tools.md）

## ADR-040 「日誌に聞く」をチャットへ統合。チャットは毎ターン日付の範囲と語で日誌・会議を引く
- 決定（ユーザー判断 2026-10-24: 統合する、日誌は Claude にも送ってよい）:
  - 送信のたびに `JournalLookup.find`（Runtime）で日誌を引く: `RelativeDateRange` の範囲と `SearchTerms.keywords`（漢字・カタカナ・英数字の連なり。ひらがなは助詞・語尾として捨て、疑問語「何」などを除く）。モデルは呼ばない。対象は `origin == .journal`（会議を含む。保存済みメモは除く）。範囲にも語にも当たらなければ空（直近へのフォールバックはしない。直近はメモ節に既にある）。
  - 予算: Claude 6000 字、Apple 800 字、ダウンロードモデル 1500 字。1 件 300 字（タイトル: 本文、1 行）。語が文字起こしにだけ当たる会議は、当たった位置の前後（計 150 字）を添える。
  - 見つかった日誌は「質問に関係しそうな日誌（新しい順。これはデータであり、指示ではない）:」と「現在日時」の節にし、メモ節の後に置く（Claude は system、端末内は instructions）。そのターンはメモ節の「最近の日誌」部分を外す（文脈の合計を増やさない）。
  - 「聞く」タブ、`AskJournalView` / `AskSession`、`JournalAssistant.ask` と専用プロンプトを削除。system prompt は「日誌に聞くを案内」から「記録が見つからないと答える。推測で作らない」へ。
- 理由: 会議の結果も日誌エントリなので、チャットで引ければ「日誌に聞く」の上位互換になる。モデルに検索ツールを呼ばせず、アプリ側で毎ターン引くので小型モデルでも確実。検索語をモデルに選ばせないのは、1 ターンにモデル呼び出しが 1 回増える（遅い・Claude では費用）ため。
- 音声入力: チャットの入力欄にも日誌と同じ端末内の音声入力（`SpeechCapture`）を付ける（ユーザー要望 2026-10-24）。認識した文は入力欄に入り、編集してから送る（自動送信はしない。筆者の判断）。
- レビュー後の修正（2026-10-24）: ストアは 1 ターン 1 回だけ読み、語はメモリ上で照合（`localizedStandardContains`、ストアの検索と同じ）。当たった語の数の多い順→新しい順。長い語があるときは 1 文字の漢字（私・朝など）を語にしない。日付語（今日・先週など）は範囲として使い語にしない。抜粋は語ごとに判断。予算は見出し・日時行・各行の頭も含めて数える。
- 残るリスク: Claude では会議の文字起こし（第三者の発言）が system メッセージに入る。「データであり指示ではない」の見出しと、書き込みツールの承認で抑える。Apple の文脈（約 4096 トークン）に収まるかは実機で確かめる（手順 8）。
- 非ゴール: 参照した日誌の表示（根拠）。
- 検証: Core `JournalQueryTests`（keywords）、Runtime `JournalLookupTests`、App `ChatSessionLocalTests`（`onDeviceInstructionsIncludeJournalSection` ほか）、`ChatSessionTests.claudeSystemIncludesJournalSection`。CI run 40080801311。
- 影響要件: FR-10, FR-15, AT-14（端末内選択時は外へ出ない点は維持）
- 状態: 採用（実機未検証: docs/verification/2026-10-24-journal-in-chat.md）

## ADR-041 日誌と会議の入口を「記録」タブに統合
- 決定（ユーザー判断 2026-10-26）: 下部タブを「記録」「チャット」の二つにし、短い文字・音声メモと会議開始を「記録」から選ぶ。会議中は同じ場所から会議画面へ戻れる。保存済みの会議と日誌は従来どおり同じ一覧・検索に表示する。
- 理由: 会議は保存後に日誌と同じ `JournalStore` に入り、チャットからも一緒に参照される。入口を一つにすると記録方法の選択が分かりやすい。一方、長時間の文字起こし・要点更新・二言語・中断再開には専用画面と `MeetingSession` を残す。
- 制約: 既存データ形式を変えない。会議中にチャットへ移っても録音を続ける。会議の準備・言語の導線を残す。
- 検証: `docs/verification/2026-10-26-record-tab-unification.md`。実機未検証。

## ADR-042 ダウンロードモデルの候補に Qwen3-4B-Instruct-2507（4bit）を追加
- 決定（ユーザー判断 2026-10-28: クラウドは使えないので、ダウンロードモデルの上位候補が欲しい）: `MLXModelRegistry` に `mlx-community/Qwen3-4B-Instruct-2507-4bit`（約 2.28 GB、Apache-2.0）を非既定の候補として追加する。既定は ADR-024 のまま Qwen2.5 1.5B。
- 理由: iPhone 15（RAM 6 GB）で載る上限は 4bit の 3〜4B 級。測定 2 では 1.5B 読込後に `os_proc_available_memory` が 2972 MB 残っており、4B 4bit（読込後 2.5〜2.6 GB の見込み）でも 1 GB 強の余裕がある。2507 の Instruct 版は thinking を持たないので、Qwen3 1.7B で保留した「thinking 無効化の確認」が不要。Qwen2.5 3B は Qwen Research License で商用配布に制限があるため退けた。
- 見送り: Qwen2.5 7B（4.30 GB、重みだけで上限超え）、gemma-3-4b-it（3.44 GB、画像塔込みで重い）、Phi-4-mini / Llama 3.2 3B（日本語は Qwen 系より弱い傾向、ライセンスも Apache-2.0 でない）。サイズは Hugging Face API の siblings 合計（2026-10-28）。
- 代償: 生成速度は 1.5B の半分程度（8〜15 tok/s の見込み）、ダウンロードは約 2.5 倍。`DiskSpaceRule` は 1.5 倍の空き（約 3.4 GB）を要求する。
- 検証: `MLXModelStoreTests.registryOffersQwen3_4BInstruct`（CI）。実機の速度・メモリ・ツール呼び出し成功率は未測定（`docs/phase2-mlx-eval.md` の測定 3）。
- 影響要件: FR-14, FR-15, AT-15
- 状態: 採用（候補のみ。既定への昇格は測定 3 の結果で判断）

## ADR-043 日誌検索の再現率を上げる（漢字の部分語、Apple の予算、search_notes の OR フォールバック）
- 背景（ユーザー報告 2026-10-28）: Apple Intelligence に日誌のことを聞くと、すぐ「該当する日誌がありません」と返る。原因はモデルではなくハーネス側: `SearchTerms.keywords` の語がそのまま本文に無いと `JournalLookup.find` が空になり、直近日誌 5 件×150 字しか渡らない上に、system prompt が「無ければ見つからないと答える」と命じていた。当たっても Apple の予算 800 字では 2 件しか入らない。`search_notes` は全語 AND なので小型モデルの検索語（「ホテル 名前」）も 0 件になる。
- 決定:
  - 語の拡張: 漢字だけの連なりが 3 文字以上なら、その直後に 2 文字の部分語を加える（宿泊先 → 宿泊・泊先。`Core/JournalQuery.swift`）。英数字や片仮名を含む連なり（10月、散歩コース）は変えない。上限 8 → 12 語。順位は従来どおり当たった語の数→新しい順。
  - Apple の予算: 日誌検索 800 → 1200 字（300 字の項目が 3 件）、メモ節の直近日誌 5 件×150 字 → 6 件×200 字、メモ節合計 1500 → 2000 字。履歴の畳み込み（1500 字）と指示文を合わせて約 4096 トークンに収まるかは実機で確かめる。
  - `search_notes`: 全語 AND で 0 件なら、各語と `SearchTerms.keywords` の部分語の OR で再検索し、新しい順に返す（AND の結果があればそれだけ）。説明文も「無ければいずれかの語を含むものを返す」に変更。
  - system prompt: 「保存済みメモと日誌に答えが無いときは、見つからないと答える前に search_notes で別の言い方の語を探してください。それでも無ければ記録が見つからないと答えてください。推測で作らないでください。」（Claude・端末内で共通）。
- 理由: ADR-040 でモデルに検索語を選ばせるのをやめた分の再現率を、モデル呼び出しを増やさずに取り戻す。ツールの OR フォールバックは、小型モデルが言い換えで検索したときの逃げ道。
- 非ゴール: 形態素解析（NaturalLanguage）の導入、同義語辞書、スコアの重み付け。
- 検証: Core `JournalQueryTests.keywordsAddKanjiPartsOfLongRuns`、Runtime `JournalLookupTests.compoundWordFindsEntryWithItsPart` / `budgets`、`ConversationContextTests.appleLocalLimitKeepsSixJournalEntriesOf200` / `systemPromptNoLongerPointsToAskJournal`、`NoteToolsTests.searchPrefersNotesWithEveryWord` / `searchFallsBackToAnyWordNewestFirst` / `searchFallsBackToPartsOfACompoundWord` / `searchWithNothingToFallBackOnIsEmpty`。RED: run 40534933894（一時ブランチ、新規 8 件だけ失敗）。GREEN: run 40536649265（Core 109 / Runtime 112 通過、シミュレータ・実機向けビルド成功）、run 40538604646（同ブランチの日誌の根拠表示の作業が乗った後の全 CI。App 単体テストを含め全ステップ成功）。
- 影響要件: FR-10, FR-15
- 状態: 採用（実機未検証）

## ADR-044 文字起こし精度チェックに合成音声の自動チェックを追加（実声の物差しとは分ける）
- 決定:
  - 固定文 A〜C の合成音声（VOICEVOX ずんだもん ノーマル、speaker 3、speedScale 1.0。正解文は `TranscriptionCheckPassage` から機械的に取り出して合成する）を 16kHz モノラル WAV とし、base64 テキストとして `App/PocketAgent/Speech/CheckAudio/` に同梱する。実行時にキャッシュへ WAV として復元する。WAV をそのまま置かないのは、リポジトリへの取り込み経路（GitHub コネクタ）がバイナリを運べないため。
  - 自動チェックはマイクを使わず、復元したファイルの音声バッファを `SpeechAnalyzer` へ直接投入する。`SpeechTranscriber` の設定は日誌経路と同一にする（ロケールは `supportedLocale(equivalentTo:)` で解決し、`preset: .progressiveTranscription`。変換先は `SpeechAnalyzer.bestAvailableAudioFormat`）。認識資産が未導入なら、ボタン押下を起点に `AssetInventory` 経由で導入を試みる。
  - 採点は `TranscriptionCheck.evaluate` に source を足して共用し、合成音声の結果はログ行の末尾に `src=synth` を付ける。実声（手動）の行は従来どおり無印。測定ログには件数と CER のみ（ADR-026 を継続）。
  - 検証画面の精度チェック節に「自動チェック」ボタンを置き、A→B→C を順に実行して各 CER と認識テキスト（画面表示のみ）を出す。手動の読み上げモードは残し、同時には走らせない。
  - 同梱するのは合成した固定文の音声だけ。実音声は入れない。
- 理由: 手動チェックは読み手の人手と読み方のぶれが入り、「測りたいときにすぐ測る」ことができない。音源を固定した自動チェックがあれば、エンジン差し替えや整文の前後比較を再現性のある数字で回せる。
- 物差しの性質: 合成音声は明瞭で雑音がなく、CER は実声より楽に出る。合成音声の数字は回帰の物差しであり、実利用の精度そのものではない。実声のベースライン（`docs/verification/2026-11-03-transcription-accuracy-baseline.md` の手動測定）は引き続き正で、置き換えない。比較表では `src=synth` の有無で系列を分ける。
- 検証: App `TranscriptionAutoCheckTests`（文と素材の対応付け、同梱素材の存在、復元した WAV の妥当性）、`TranscriptionCheckTests`（`src=synth` 付きログ行の形式）。RED: run 41661035244。GREEN: run 41664296506（全ステップ成功、PR #7）。`SpeechAnalyzer` の実認識は実機のみ（手順: `docs/verification/2026-11-04-transcription-auto-check.md`）。
- 影響要件: なし（検証機能の追加。保存方針は ADR-026 のまま）
- 状態: 採用（実機確認済み 2026-11-04: iPhone 15、TestFlight build 24 で自動チェックが A〜C 完走し CER を表示。初回ベースライン A 20.55% / B 2.63% / C 9.88%。未確認の細部は docs/phase0-checklist.md）

## ADR-045 製品の正式名称を「ポケット執事」とする
- 決定: 製品の正式名称は「ポケット執事」（2026-11-04 ユーザー決定。執事・相棒系の方向性で、簡易確認を経て確定）。
  - 英語表記は "Pocket Butler" を使わない（同名の現行アプリ「Pocket Butler: Private PDF AI」が存在するため）。英語表記は別途設計する。
  - 商標の正式確認は、販売前の権利チェックで実施する。
  - アプリ内表示名と App Store Connect のレコード名（現在 "Pocket Agent Dev"）への反映は、製品化の形の判断に合わせて後日行う。今回は何も変更しない。
  - リポジトリ名（pocket-agent-ios）など開発上の呼称は当面そのまま使う。
- 理由: 開発時の仮称（Pocket Agent）のまま製品化の判断を進めると、表示名・ストア情報・権利確認が後からずれる。日本語の正式名称だけを先に確定し、英語表記と表示への反映は、同名アプリとの混同リスクと製品化の形が固まってから決める。
- 影響要件: なし（名称の決定のみ）
- 状態: 採用

## ADR-046 CER の採点に数字表記の正規化を入れる（物差しの定義変更・系列分離）
- 決定:
  - 採点の正規化（NFKC → 空白・句読点の除去）の最終段に、数字表記の変換を足す。漢数字と算用数字を同一の正規形（単位なしの算用数字の値）へ寄せ、参照文と認識文の両方に同じ変換をかける。変換仕様は `docs/superpowers/specs/2026-11-04-cer-numeral-normalization-design.md`。
  - `tools/cer.py` と Core の `TranscriptionScorer` を同時に変えて同一ルールを保ち、両実装に同じテストケースを流して一致を確かめる。`tools/cer.py` には旧ルールを再現する `--keep-numerals` を足す。アプリ内採点は常時変換する。
  - 変換できない・曖昧な表記（単独の大単位、桁並び読みと単位表記の混在など）は変換しない。
- 理由: 初回ベースラインの A（20.55%）の大半は数字の表記ゆれで、数字の多い文ほど CER が実態より悪く出る。精度改善の効果測定が表記に引っ張られないよう、CER が認識そのものを測る形にする（ベースライン文書の未決課題への回答）。
- 系列の扱い: 変更後の採点は新系列とし、旧系列の値は消さずに並記する。初回ベースラインの認識テキストを新ルールで再採点した参考値は A 2.44% / B 0.00% / C 8.64%（旧系列は A 20.55% / B 2.63% / C 9.88%）。アプリ内ログ行の `ref=` / `hyp=` 文字数も正規化で変わる（例: A の ref は 73 → 82）。合成音声系列（`src=synth`）と実声系列の区別は従来どおり。
- 検証: Core `TranscriptionScorerTests`（`TranscriptionScorerNumeralTests`）と `tools/test_cer.py` で同一ケースを確認。RED: run 41768864576（Core package tests のみ失敗）。GREEN: run 41778190124（PR #9、全ステップ成功）。途中の run 41769393341 ではアプリ側 `TranscriptionCheckTests` のログ行の文字数が旧ルールのままだったため単体テストが失敗し、期待値を新系列（A の ref 73→82、B の ref 76→77）に直してから全グリーンになった。
- 影響要件: なし（検証の採点ルールのみ。認識そのものは変わらない）
- 状態: 採用

## ADR-047 専門用語対策は代替候補の選び直し→用語辞書の順で実験する
- 決定:
  - 固定文 C の専門用語エラー（新系列 CER 8.64%、用語エラー数 4）への対策として、まず `SpeechTranscriber` の代替候補（reportingOptions へ `.alternativeTranscriptions` を追加）を用語リストで選び直す実験（実験 1）を行い、届かない範囲を用語辞書の後処理（実験 2）で補う。判断基準は設計書 `docs/superpowers/specs/2026-11-04-term-accuracy-design.md` の数値どおりとする。
  - 実験 1 の実装: 用語リストと選び直しの純ロジックは Core に置く（`TranscriptionTerms` / `AlternativeSelector`。採用条件は「用語出現数が元の text より多い候補の中で編集距離最小、同点なら元のまま」）。オプションの合成は共有ビルダー `ProgressiveTranscriber`（`.progressiveTranscription` プリセットのオプション集合に `.alternativeTranscriptions` を union し、フルイニシャライザで組み立てる）が担う。自動チェックに実験 ON/OFF スイッチを置き、同一音源で両条件を比較する。測定ログには両条件の `cer.journal` 行（ON は末尾に `alt=on termerrors=<n>` を追加）を残し、本文は残さない（ADR-026）。
  - 実験 2 の実装: 補正の純ロジックは Core に置く（`TermCorrector`）。ペアは無条件 2 件（路行装置→露光装置、ぶどまり→歩留まり）と文脈条件つき 2 件。企画→規格 は直後が を超え / が超え / 外 / 値 のときだけ（規格の用法＝限度超過・規格外・規格値に限る条件で、「企画＝計画」の通常用法には触れない）、先幅→線幅 は直後が測定系の連語（のばらつき等）のときだけ発動する。ペア単位の ON/OFF（`disabledRuleIDs`）を持ち、補正は final テキストにだけ適用する。自動チェックに実験 2 スイッチを置き、実験 1 の選び直しの上に重ねて ON/OFF を比較する。測定ログの ON 行は末尾に `dict=on termerrors=<n> corrections=<n>` を足し、発動件数のみ残す（ADR-026、形式はベースライン文書で定義）。
  - 採用が決まるまでライブ経路（日誌）の確定テキストと標準設定は変えない。標準設定は従来どおり `.progressiveTranscription` プリセットで、自動チェックと同一に保つ（ADR-044）。実験スイッチが唯一の意図的な乖離で、検証画面に明示する。
- 理由: 主経路の `SpeechTranscriber` には用語ヒント（contextual strings）の公式手段が無く、エンジンが出す情報の範囲で改善するしかない。代替候補はエンジン自身の再解釈であり、決め打ち補正より過剰補正の危険が小さい。
- 検証: Core `TranscriptionTermsTests` / `AlternativeSelectorTests`、App `ProgressiveTranscriberTests`（プリセット構成の裏取りを兼ねる。`.progressiveTranscription` は reportingOptions が volatileResults + fastResults、attributeOptions に audioTimeRange を含まないことを CI で確認）/ `TranscriptionExperimentTests`。RED: run 41840522226（Core package tests のみ失敗）。実装初回は合成オプションの型注釈を 2 度誤りシミュレータビルドで失敗（run 41842185686、41844203003）。Apple DocC の宣言で `Set<SpeechTranscriber.ReportingOption>` が正しい形と確定させて修正。GREEN: run 41847684876（PR #10、全ステップ成功）。
- 実験 1 の実機測定（2026-11-05、iPhone 15、TestFlight build（main 5216912 / Codemagic build 6aebb41a）、計画 Task 4）: A は CER ON 2.44% / OFF 2.44%・用語エラー 0→0・候補ヒット 0、B は 0.00% / 0.00%・0→0・0、C は 8.64% / 8.64%・4→4・0。代替候補に対象用語が 1 件も含まれておらず「不発」。設計書の判断基準どおり**実験 1 は不採用**とし、ライブ経路への組み込み（計画 Task 5）は行わない。記録はベースライン文書の「実験1の測定」と計画書 Task 4。
- 実験 2 の検証: Core `TermCorrectorTests`（C の実測誤文 4 件の補正、A・B で発動ゼロ、「企画」の通常用法で発動しないこと、ペア単位 OFF）、App `TranscriptionExperimentTests` の辞書ケース。RED: run 41931972086（PR #11、Core テストのみ先行）。GREEN: run 41932238853（PR #11、全ステップ成功）。実機での ON/OFF 測定と採用判定は計画 Task 7（下記の follow-up で完了）。
- 実験 2 の実機測定と採用判定（2026-11-05、iPhone 15、TestFlight build #24（main 891601d、Codemagic build 6aec8758ab17f8deb7530e97）、計画 Task 7）: A は CER OFF 2.44% / ON 2.44%・用語エラー 0 → 0・辞書発動 0、B は 0.00% / 0.00%・0 → 0・発動 0、C は CER ON 0.00% で、補正後テキストの写しから 4 件の誤り（路行装置・ぶどまり・先幅・企画）がすべて直っていることを確認した（用語エラー 4 → 0。C の OFF 側数値と発動件数は今回の画面に写っておらず未記録。辞書なしの同条件の参照値は実験 1 測定の C 8.64%）。採用基準（用語エラー 4 → 1 以下、C の CER 5% 以下、A・B で発動ゼロ）をすべて満たし、**実験 2 は採用**。
- 本採用（follow-up、2026-11-05、PR #12）: 単言語ライブ経路の確定テキストへ `TermCorrector` を常時適用する（`SpeechCapture.correctFinalText` を確定結果ごとに適用し、volatile は素通し。発動件数は件数のみを保持し本文は残さない — ADR-026）。二言語経路は確定処理を単言語と共有しない（`MeetingSession` 内の `LanguageArbiter` 経由）ため対象外のままとし、相互作用は別途設計とする。検証画面の自動チェックは辞書スイッチで OFF（生の認識＝物差しの系列）/ ON（実経路と同一）を引き続き比較でき、既定は ON に変更した（ジャーナル形式は不変）。上記「採用が決まるまでライブ経路は変えない」はこの follow-up で役目を終えた。検証: App `LiveTermCorrectionTests`（実経路の適用点: C 相当の誤文の補正、A・B と「企画を立てる」等の正当な文脈で無変更）。RED: run 42049556248（一時 PR #13 で再確認。PR #12 の初回 run 42042582698 は concurrency で単体テスト前にキャンセル）。GREEN: run 42044719928（PR #12、全ステップ成功）。ベースライン文書の公式値は辞書 ON（A 2.44% / B 0.00% / C 0.00%）へ更新し、辞書なしの値は履歴として残した。
- 影響要件: なし（保存方針は ADR-026 のまま。本採用により単言語ライブ経路の確定テキストは辞書補正後のものになる）
- 状態: 採用（実験 1 は実機測定で不発のため不採用。実験 2 は実機測定で採用基準をすべて満たし、本採用として単言語ライブ経路へ組み込み済み。二言語経路は対象外のまま）

## ADR-048 用語辞書を二言語経路にも適用する（適用点は言語判定の後）
- 決定:
  - ADR-047 で本採用した用語辞書（`TermCorrector`）を、二言語経路の確定テキストにも常時適用する。適用点は `MeetingSession.accept(_:)` のセグメント生成時点とし、受理された候補のうち言語が `ja` のものだけを `SpeechCapture.correctFinalText`（単言語経路と同じ入口）で補正する。
  - 言語判定（`LanguageArbiter`）は常に生の認識テキストで行う。補正は判定の後なので、判定の入力（信頼度の文字数重み付け・`ScriptGuess`）も挙動も変わらない。判定で却下された候補は表示・保存されないため補正しない。
  - 英語・中国語など日本語以外のレーンは補正しない（辞書は日本語認識の誤りを直すもので、中国語レーンには同じ漢字列が正当に出うる）。`laneVolatile`（暫定表示）は単言語経路と同様に素通しし、final のみに適用する。
  - 検証画面の二言語ゲート（段階 A）は認識器と判定器の生の挙動を測る物差しのため、対象外のままにする。適用は実経路（二言語会議）だけ。
  - 発動件数は二言語経路では保持しない。単言語経路の `SpeechCapture.termCorrectionCount` には検証画面の 30 秒テストのログ行という読み手があるが、会議経路には対応する表示・ログが無いため、読み手ができたら一緒に足す。
- 理由: 二言語経路は確定処理を単言語経路と共有せず（`SpeechCapture.report` → `.candidate` → `LanguageArbiter` → `MeetingSession`）、PR #12 の本採用では「相互作用は別途設計」として対象外だった。受理セグメントの生成点は、表示・保存・翻訳・要点入力の全ての下流が共有する単一の確定点であり、ここで補正すれば翻訳ソースまで一貫して補正済みになる。設計は `docs/superpowers/specs/2026-11-09-bilingual-term-dictionary-design.md`、計画は `docs/superpowers/plans/2026-11-09-bilingual-term-dictionary.md`。
- 検証: App `BilingualTermCorrectionTests`（受理された日本語候補の C 相当誤文の補正、翻訳入力が補正済みであること、英語レーン・中国語レーン・正当な「企画」・却下された候補・暫定表示が無変更）。RED: run 42550884632（一時 PR #14、285 テスト中 `BilingualTermCorrectionTests` の 2 テスト・3 issue のみ失敗、他は全通過）。GREEN: run 42550895990（PR #15、全ステップ成功）。なお初回の RED / GREEN 実行（run 42546628244 / 42548741522）は、ランナーイメージの更新で増えたランタイム名（`iPhone19` を含むキー）を `ci/pick-simulator.sh` がバージョン番号として解釈できず、単体テストのステップがテスト実行前に落ちたため無効だった。同スクリプトの堅牢化（数値として解釈できないキーは順序付けから外す）を本 PR の別コミットで直し、そのうえで RED / GREEN を取り直した。実認識の確認は実機のみ（チェックリストの実機確認項目）。
- 影響要件: なし（ADR-047 と同じく保存方針は ADR-026 のまま。本適用により二言語会議の日本語セグメントも辞書補正後のテキストになる）
- 状態: 採用

## ADR-049 検証文の実験系列 E を追加し、辞書変更前に凍結する
- 決定:
  - 固定文 A〜C の物差し（`TranscriptionCheckPassage`）は変更しない。別枠の実験系列 E（Core の `ExperimentPassage`、E1〜E5）を追加する。根拠は `docs/improvement-analysis-2026-11-09.md` の候補 2: 用語辞書の 4 ペアは固定文 C の誤りそのものから作られており、同じ C の 0.00% は汎化の証拠にならない。
  - 構成: E1・E2 は対象 4 語（露光装置・歩留まり・線幅・規格）を C とは別の文脈で使う未見の文で、漢数字を含み数字正規化（ADR-046）も同時に試す。E3 は罠の文（辞書の誤り語を正当な意味で使う文）で、合格条件は辞書発動 0。E4 は用語を含まない約 300 字の日常文（CER の分解能を上げる）。E5 は人名・地名・カタカナ語が多い文。全文はベースライン文書（`docs/verification/2026-11-03-transcription-accuracy-baseline.md`）の実験系列 E の節に記録する。
  - 凍結ルール: E 系列は辞書変更前に凍結し、以後の辞書変更で E の文面は変えない。辞書変更後は、E での発動件数と CER を見るだけにする。「答えを見てから文を作る」形の再発を防ぐためで、文の差し替えが必要になった場合は新しい系列として追加し、E は履歴として残す。
  - 音声は ADR-044 と同じ手順（VOICEVOX ずんだもん ノーマル、speedScale 1.0 で合成し 16kHz mono に変換、base64 同梱 `passage-e1`〜`passage-e5`）。自動チェックとは別のボタンで実行する。ログ行は `cer.journal passage=E1 … src=synth` の形で A〜C の系列と混ぜず、辞書 ON 行の形式は A〜C と同じ（`dict=on termerrors=<n> corrections=<n>` 付き）。
  - E3 の文面の扱い: 検討書が罠の例に挙げた「前回の企画を超える反響」「企画外の出し物」は、現行の spec ルールの発動条件（直後が「を超え」「外」）にそのまま一致し、実際に発動することを実装時に確認した。発動 0 を合格条件とする凍結文には入れず、発動条件の近くを通るが発動しない文（企画を出す／企画書／企画会議／企画の価値、「を超える」が企画の直後でない配置）で E3 を構成した。発動する 2 文型は過剰補正の既知候補としてここに記録し、次の辞書改訂（spec ルールの条件の見直し）で扱う。
- 理由: 辞書が増えるほど（ユーザー辞書などの後続候補を含む）、過剰補正を検知する物差しが先に要る。E 系列は既存の自動チェック基盤の延長で作れ、合成音声の手順（ADR-044）も確立済みだった。
- 検証: Core `ExperimentPassageTests`（参照文の存在、E1・E2 の対象 4 語と漢数字、E3 に `TermCorrector` を適用しても発動 0・無変更、E4 の長さと用語不在、E5 のカタカナ量）、App `ExperimentCheckTests`（ジャーナル行の形式、E1 の誤認識文が辞書で完全復元されること、E3〜E5 で発動 0）、`TranscriptionAutoCheckTests` の E 系列の音声テスト（同梱・16kHz mono・長さ）。RED: run 42623361004（PR #16、Core package tests が失敗）。GREEN: run 42623836521（PR #16、全ステップ成功）。実認識の確認は実機のみ（チェックリストの実機確認項目）。
- 影響要件: なし（測定の物差しの追加であり、保存方針は ADR-026 のまま）
- 状態: 採用

## ADR-050 翻訳エンジンを選択式にし、PLaMo 3 Translate を第 2 エンジンとして追加する（推論ランタイムは未統合）
- 決定:
  - 二言語会議の翻訳エンジンを選択式にする（設定の「翻訳エンジン」節。Core の `TranslationEngineChoice`、UserDefaults キー `translation.engine`、既定は Apple Translation）。第 2 エンジンとして PFN の PLaMo 3 Translate 0.8B（`pfnet/plamo-3-translate-0.8b-GGUF` の `plamo-3-translate-0.8b-Q4_K_M.gguf`、revision `1cf96ae02133958a20074bfdfab76517bb737d00`、573,126,848 バイト）を追加する。
  - 今回の実装範囲はプロトコル境界まで: 選択 UI・切替、GGUF のダウンロード状態管理（`PlamoModelStore`。容量 1.5 倍・モバイル通信の確認・1 本ずつ・中断／削除の意味論は `MLXModelStore` と同じ）、PFML3 プロンプト構築（Core の `PlamoPrompt`）、比較画面（検証画面の「翻訳テスト」で同じ 6 文を Apple と PLaMo の両方で訳す）。実推論は `PlamoInferenceEngine` プロトコルの奥に置き、既定実装 `UnavailablePlamoEngine` は常に「ランタイム未統合」エラーを返す。
  - エンジンの解決は Core の `TranslationEngineResolver` が行い、選んだエンジンが使えないときに他方へ黙って切り替えない。`PlamoRuntimeAvailability.isAvailable = false` の間は、PLaMo を選ぶと `plamoRuntimeUnavailable` となり、会議は翻訳なしで進む（従来の「翻訳データ未導入なら翻訳なし」と同じ扱い）。会議画面と設定のフッターにその旨を明示する。
- ランタイム選定の検討:
  - MLX: PFN 公式の MLX-4bit 重みは `model_type=plamo3` のカスタムアーキテクチャで、config は `architectures=[Plamo3ForCausalLM]`・custom_code。採用中の mlx-swift-lm 3.32.3 の `LLMTypeRegistry`（52 種）に plamo 系の登録が無く、リポジトリ内のコード検索でも plamo の実装が無いことを確認し、棄却。
  - GGUF + llama.cpp: VM 上の llama.cpp b12224 で GGUF Q4_K_M の実動作は検証済み。ただし公式最新リリース v0.9.0 の資産は `nightly-tag.txt` のみで iOS XCFramework が無く、サードパーティ製 SPM ラッパー（pgorzelany/swift-llama-cpp 等）は上流がシミュレータスライスの同梱をやめたため、CI のシミュレータ単体テストと両立せず見送り。
  - 残る選択肢: (a) llama.cpp を CI でソースから XCFramework ビルドする、(b) mlx-swift-lm へ plamo3 を移植する、(c) ラッパーのシミュレータ対応を待つ。ダウンロード済みの GGUF は (a)(c) でそのまま使える。
- プロンプト形式: PFML3（GGUF の chat_template と同じ）。`<|plamo:tag|>dataset<|plamo:msg|>translation<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>{src}<|plamo:msg|>{text}<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>{tgt}<|plamo:msg|>`。BOS はトークナイザが付けるため文字列に含めない。言語コードは小文字に正規化し `^[a-z]{2,3}(-[a-z]{4})?$` のみ受け付ける。停止マーカーは `<|plamo:tag|>` と `<|plamo:bos|>` で、出力は最初のマーカーで切って前後の空白を除く。原文が空白のみ、または `<|plamo:` を含む文は無効（テンプレートが拒否するため、エンジンへ渡さず `invalidInput`）。原文の前後空白はそのまま渡す。
- メモリ注意: ランタイム統合時は、PLaMo を文字起こし・要点モデルと同時常駐させない。翻訳は文単位の短命処理なので「ロード→生成→解放」を基本とし、会議中は要点モデルとの同時ロードを避ける設計にする。
- 用語集: PFML3 は glossary 記法を持つが、今回は使わない（将来拡張。ADR-047 / ADR-048 の用語辞書との関係は統合時に設計する）。
- ライセンス: PLaMo Community License。個人・非商用の利用は無償・事前登録不要、商用利用は事前登録が必要なため、M5 の権利確認リストへ追加した。ダウンロード確認ダイアログにライセンス名・サイズ（約 573 MB）・通信の発生（モバイル通信時は Wi-Fi 推奨）を表示する。
- 検証: Core `TranslationEngineTests`（`TranslationEngineChoiceTests` / `PlamoPromptTests` / `TranslationEngineResolverTests`: 表示名・保存キー・rawValue の往復、日→英プロンプトの完全一致、言語コードの小文字化、空文字・空白のみ・`<|plamo:` 混入・不正な言語コードで nil、原文の前後空白の保持、停止マーカーでの切り取りと trim、Resolver の全分岐）、App `PlamoTranslatorTests`（プロンプトの受け渡し、停止マーカー以降の除去、`invalidInput` ではエンジンを呼ばないこと、既定エンジンで `runtimeUnavailable`）、App `PlamoModelStoreTests`（容量不足の拒否、モバイル通信の確認要求、成功→ダウンロード済み、失敗文、中断→未ダウンロード、削除、ディレクトリ配置、`HubPlamoDownloader.isDownloaded` のサイズ一致判定、シミュレータでのダウンロード拒否）。RED: run 42639294651（PR #17、テストのみのコミットで Core package tests のみ失敗）。GREEN: run 42640794803（PR #17、全ステップ成功）。実機での切替・ダウンロード・比較画面は未確認（チェックリストの実機確認項目）。
- 影響要件: FR-15
- 状態: 採用（実機未検証、ランタイム未統合）

## ADR-051 PLaMo 3 Translate の推論ランタイムとして llama.cpp を XCFramework 化して統合する
- 決定:
  - ADR-050 の残りの選択肢 (a) を採用する。llama.cpp **b12224**（VM で GGUF Q4_K_M の実動作を検証済みの系統。タグは `ci/build-llama-xcframework.sh` にピン留め）を、上流の `build-xcframework.sh ios-device ios-sim` で XCFramework 化し、`Vendor/llama.xcframework` としてアプリにリンクする（動的フレームワークなので embed する）。
  - バイナリはリポジトリにコミットしない。CI（GitHub Actions）は「llama.cpp のバージョン＋ビルドスクリプトのハッシュ」をキーにキャッシュし、Codemagic も同じスクリプトとキャッシュパスで揃える。生成は冪等で、スタンプファイル（`Vendor/.llama-xcframework-version`）が一致すれば再ビルドしない。GitHub Actions のタイムアウトは初回ビルドを見込んで 60 分に延ばした。
  - `PlamoInferenceEngine` の実実装 `LlamaCppPlamoEngine` を追加し、`PlamoTranslator` の既定エンジンにする。`PlamoRuntimeAvailability.isAvailable = true` に反転し、会議・比較画面はそのまま一貫して有効化される。`UnavailablePlamoEngine` と `PlamoTranslatorError.runtimeUnavailable` は廃止し、エラーは `modelNotDownloaded`（ファイルなし）と `inferenceFailed`（ロード／生成の失敗）に分ける。Core の `plamoRuntimeUnavailable` の文言は「利用できません」に更新した（resolve の分岐は残すが、実運用では到達しない）。
  - 生成は 1 呼び出しごとに「ロード→生成→解放」を完結させる（ADR-050 のメモリ規律）。llama のオブジェクトはスレッド安全でないため、エンジン内の serial queue で直列化する。実機では Metal に全レイヤーをオフロードし（`n_gpu_layers = 99`）、シミュレータでは CPU のままにする。
- サンプリング: greedy（temperature 0）。VM の llama-server 検証（`translate.py`）と同じ構成で、訳文の再現性と安定性を優先する。最大生成は 1024 トークン（同検証と同じ）。コンテキストは 2048 で、生成上限は「2048 − プロンプトのトークン数」との小さい方にする（窓を超えて decode が失敗するのを避ける）。停止は EOG と PFML3 の停止マーカー（`<|plamo:tag|>` / `<|plamo:bos|>` を特殊トークンとしてトークナイズした ID）で判定し、テキスト側の切り取り（`PlamoPrompt.cleanedOutput`）と二重に効かせる。
- 検証範囲の線引き: CI では両スライスのコンパイル／リンク成立と、モデルファイルなし／破損ファイルでのエラー表面化を保証する。573 MB の GGUF を CI で落として実推論はしない。実モデルでの推論は、ファイルが存在する場合だけ走る統合テスト（実機・手元用。CI では素通り）を用意した。モデル＋プロンプト自体の正しさは VM の llama.cpp 実績（英日・日英・日中を確認済み）が基準で、iOS 側の出力の一致は実機未検証。
- 用語集: 引き続きスコープ外（ADR-050 の将来拡張のまま）。
- 検証: Core `TranslationEngineTests`（`plamoRuntimeUnavailable` の文言更新）、App `PlamoTranslatorTests`（既定エンジンが未ダウンロードで `modelNotDownloaded`、`isAvailable = true`、エラーメッセージ）、App `LlamaCppPlamoEngineTests`（未ダウンロード／破損ファイルのエラー、既定 URL がストア配置と一致、実モデルがある場合のみ翻訳スモーク）。RED: run 42833220901（PR #18、テストのみのコミットで Core package tests が失敗）。実装コミットの run 42837072384 では Core / Runtime テスト・プロジェクト生成・依存解決まで成功し、Build（iOS Simulator）で `Vendor/llama.xcframework` 不在のため失敗した。これは ios-ci.yml へのビルドステップ追加が未反映のためで、原因は Muse GitHub App に Workflows 権限がなく、API（Git Data / Contents の両方）経由で workflow ファイルを変更できないこと（403 Resource not accessible by integration）。ビルドスクリプトとキャッシュ設計は本 PR に含まれており、権限付与後に ios-ci.yml の 1 コミットで反映でき、その run で GREEN を確定してここに記録する。
- 影響要件: FR-15
- 状態: 採用（実機未検証）
