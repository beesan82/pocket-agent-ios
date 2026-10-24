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
- Apple ローカルにツールを渡すときは必ず `ToolApprovalGate.wrap` の戻り値を使う。チャットは Apple ローカルのクライアントへ、`ToolApprovalGate.wrap` で包んだ 5 つのメモツール（save_note / edit_note / list_notes / search_notes / delete_note）を渡している。承認シートで拒否された呼び出しも「試行」として記録される（ADR-028）。
- 検証: `ApprovalGatedToolTests` 8 件（CI run 39101910024）。FoundationModels セッション内からの実呼び出しは第1段階の TestFlight で確認予定（docs/verification/2026-10-19-apple-local-tools.md）。
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
- 状態: 採用（Phase 2 時点。後続設計で置換予定）

## ADR-022 質問は 2 段階: 日付範囲を母集合とし、語は絞り込みだけに使う
- 決定: 1 段目で相対日付（先週・一昨日など）を範囲に解決し、その範囲を母集合とする。検索語は母集合を絞り込むだけで、語で母集合を広げない。ヒットが無い場合は直近 10 件へフォールバックし、画面上でそれと分かる表示を付ける。
- 理由: 小型モデルの語抽出は不安定。範囲が確定していれば語の失敗が致命的にならない。フォールバックを明示して根拠のない回答を避ける。
- 影響要件: FR-15
- 状態: 採用（自動テストは Core 68 件に含む。実機での「先週」・キーワード・ヒット無しは未検証）

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
- 状態: 採用（設定の階層 UI、チャット往復、機内モード、停止、ダイアログ表示は実機未検証）

## ADR-032 日誌タブは設定の端末内モデルに従う（Apple が使えれば Apple、それ以外はダウンロードモデル）
- 決定: 日誌の要約と「日誌に聞く」は、設定で Apple を選んでいてこの端末で使えるなら Apple（`FoundationModelsClient`、ツールなし）、それ以外（Claude 選択時、ダウンロードモデル選択時、Apple 不可の端末）はダウンロードモデルを使う（ユーザー判断、2026-10-22）。Claude は日誌に使わず、日誌の経路は API キーを読まない。判定は Core の `JournalModelRule`。Apple 選択で使えない場合は「Apple は使えないため、ダウンロードモデルを使います」と表示する。Apple は文脈が小さい（約 4096 トークン）ため、「日誌に聞く」に詰める日誌は Apple 1500 字、ダウンロードモデル 3000 字。要約の入力は切り詰めず、超過時は既存の固定の失敗文を出す。ADR-026 までの「日誌は常にダウンロードモデル」を置き換える。
- 検証: `JournalModelRuleTests`（4 規則＋可用性は Apple 選択時のみ確認）、`JournalAssistantTests.askUsesContextBudget`、`JournalModelAccessTests`（Apple は読み込みなしで準備完了、ダウンロードモデル経路は従来どおり）。CI run 39692758413（Core 87 / Runtime 96 / App 156）。
- 影響要件: FR-15, AT-14
- 状態: 採用（Apple での要約・質問は実機未検証: シミュレータでは動かず、iPhone 15 は Apple Intelligence 非対応。1500 字が文脈に収まるかも未確認）
