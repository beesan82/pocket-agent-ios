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

## Phase 1（プレーン版）: チャット・メモ・LINE返信
設計: `docs/superpowers/specs/2026-10-18-phase1-chat-memo-line-design.md` / 計画: `docs/superpowers/plans/2026-10-18-phase1-chat-memo-line.md`
最終 CI: run 39114462235（commit `2f6077e`）— Core 31 / Runtime 54 / App 37 テスト合格、ビルド成功。

### 実装済み（CI で自動テスト合格。いずれも実機では未確認）
- [x] Task 1 メモ（`Note` / `NoteStore` / `InMemoryNoteStore`、`appInternalDelete`）— `bb5209f..7b64ac7`、RED 39108346748 / GREEN 39108395807
- [x] Task 2 `ShareFlow`（送信完了状態なし、AT-07）— `..763732d`、RED 39108702446 / GREEN 39108753238
- [x] Task 3 `ConversationApprovals`（会話単位の許可、ADR-013）— `..8b97846`、RED 39109080032 / GREEN 39109172255
- [x] Task 4 メモツール 4 種（ADR-014）— `..42e3b38`、RED 39109560120 / GREEN 39109697611
- [x] Task 5 `ConversationContext`（履歴の上限・システムプロンプト）— `..3c14c25`、RED 39110047063, 39110149495 / GREEN 39110240692
- [x] Task 6 SwiftData 永続化（会話・メモ・全削除）— `..e625472`、RED 39110953066 / GREEN 39111458131
- [x] Task 7 `ChatSession` / `ApprovalBroker`（承認の直列化）— `..1f41596`、RED 39112006112 / GREEN 39112331406
- [x] Task 8 画面一式（会話一覧・チャット・承認・返答操作・メモ・設定）— `..1620625`、レビュー修正後 CI 39113298313
- [x] 最終レビュー修正（C1 Apple 畳み込みプロンプト、I1 id 指定の拒否、I2 LINE ダイアログ、I4 バナー文言、M1〜M3）— `1620625..2f6077e`、RED 39114116464, 39114202188 / GREEN 39114462235
- [x] ADR-013〜019 を `docs/decisions.md` に記録。逐次表示は未実装（ADR-015、FR-01 からの意図的な逸脱）

### 実機で未検証
- [ ] 貼り付け → 下書き → 「LINEで共有」→ LINE の共有先選択画面。ダイアログの表示順で LINE が確実に開くか（I2: キャンセル役ボタンが外側タップでも発火するか）
- [ ] メモを保存 → 後日チャットで尋ねて答えるか
- Apple ローカルでの複数ターンとツール呼び出し（畳み込みプロンプトは fake でのみ確認、ADR-017）。手順と記録欄は docs/verification/2026-10-19-apple-local-tools.md
  - [ ] 「私の名前はケイタ 覚えておいて」→ 承認シートが出るか
  - [ ] 新しい会話で「私の名前は？」→ 注入されたメモで答えるか
  - [ ] 「ケイタをケイタさんに直して」→ `edit_note` が呼ばれるか、または救済されて承認シートが出るか
- [ ] 機内モード（AT-02 / AT-14）
- [ ] 承認シートが連続して出るか、シートの再表示のちらつき（I1: 下スワイプ後、`onDisappear` の拒否までの間に再提示されないか）
- [ ] 承認シート表示中の停止、および FoundationModels がキャンセルをツール承認待ちへ伝えるか
- [ ] `FMSchemaConverter` が引数なしの `list_notes` スキーマ（空オブジェクト）を受け付けるか
- [ ] CoreData のサンドボックス警告 / 初回起動時のストア作成

### バックログ（Phase 1 で見送った小さな問題）
- `NoteSearch` が `localizedStandardContains`（ロケール依存）に依存。SwiftData 側は `NoteSearch.matches` を再利用する方針
- `ShareFlow`: 文面なしの文言 `共有する文面がありません` が 2 か所に重複。`didOpen` の確認中以外での無視や任意状態からの request/cancel のテストなし
- 初回の承認が同一ツールで並行すると両方出る（`ApprovalBroker` の直列化で緩和済み）。名前キーのストアをリスク判定より先に参照
- `NoteTools`: 件数のみの切り詰めテストなし、`deleteAsksEveryTimeOnBothPaths` が両経路を 1 件に統合、スキーマ形状のアサーションなし
- `ConversationContext`: 後で落とされる先頭のアシスタント文も文字数予算に数える。`ConversationContextTests.swift:155` のコメントが紛らわしい
- `SwiftDataNoteStore`: `createdAt` 同値時の順序が fetch 順に依存。`eraseAll` 失敗の集約が未テスト。不明な `roleRaw` は黙って捨てる。保存失敗時のロールバック（M3）は自動テストなし
- キュー中の承認要求のキャンセル経路が未テスト
- 「全データ削除」が `ModelSettings` をリセットしない（ダイアログは「すべて」と表示）
- `ChatView` の `ForEach` がオフセットをキーにしている
- 承認シートのボタンは `broker.answer`（id 指定でない）。二重タップが次の要求に答える恐れ。`answer(id:_:)` 化が必要
- Apple の畳み込みプロンプトは履歴だけを予算化し、今回のメッセージで 4000 文字を超え得る（文脈超過の文言で対処）
- 「（空の応答）」のプレースホルダ ターンが履歴として再送される

## Phase 2（端末内 MLX 日誌）
設計: `docs/superpowers/specs/2026-10-18-phase2-mlx-journal-design.md` / 計画: `docs/superpowers/plans/2026-10-18-phase2-mlx-journal.md` / 評価: `docs/phase2-mlx-eval.md` / ADR-020〜026
最終 CI: run 39284990942（commit `bd29e5e`）— Core 68 / Runtime 64 / App 112 テスト合格、シミュレータ・実機ビルド成功。

### 実装済み（CI で自動テスト合格）
- [x] Task 1 MLX 依存の固定とリンク（ピン一致 10 件）— `47cd788..172f682`、RED 39125196666 / GREEN 39125512289
- [x] Task 2 日誌ドメイン（`JournalEntry` / `JournalStore` / `JournalNoteStore`）— `..ae1109a`、RED 39126122487 / GREEN 39126567706
- [x] Task 3 検索・要約ロジック（相対日付・検索語・パッカー・`SummaryParser`・`DiskSpaceRule`）— `..14974d6`、RED 39127192201 / GREEN 39127655341
- [x] Task 4 `MLXModelStore` / `MLXRuntime`（単一ロード、ローカルディレクトリ読み込み）— `..14aacaa`、RED 39130119370 / GREEN 39130581076
- [x] Task 5 `SpeechCapture`（SpeechAnalyzer）— `..e408fdc`、GREEN 39136219330
- [x] Task 6 MLX 検証画面 — `4fb8834`、GREEN 39137891881。6b 測定ログ `b265936`（GREEN 39151835083）、6c 開発者モードの Issue 送信 `2d12083`（GREEN 39178311475）、6d 測定サマリー `460cb4a`（GREEN 39250883177）
- [x] Task 7 `JournalAssistant`（要約・2 段階質問）— `8505cb9`、RED 39139629022 / GREEN 39141223599
- [x] Task 8 SwiftData V1→V2 と NoteRecord 移行 — `ed15b33`、RED 39142898098 / GREEN 39144321684
- [x] Task 9 日誌 3 タブ UI・収録→要約→保存・質問 — `02f1eb6`、RED 39268450066 / GREEN 39271832051
- [x] 最終レビュー修正（破棄確認、背景／メモリ解放での生成停止、測定ログ消去、NoteRecord 残骸の削除、文字起こし検索、一昨日、月曜始まり）— `bd29e5e`、RED 39278162447 / GREEN 39284990942
- [x] ADR-020〜026 を `docs/decisions.md` に記録

### 実機で確認済み
- [x] AT-03 非対応端末の理由表示（2026-10-19、iPhone 15、TestFlight ビルド 4）— Apple ローカルの行が無効で「この端末はApple Intelligenceに対応していません」を表示、クラッシュなし
- [x] 音声入力（SpeechTranscriber ja-JP）が iPhone 15 で利用可能（ビルド 5、30 秒で 86 字）
- [x] MLX Qwen2.5-1.5B の要約: 短文 3.0 秒 / 中文 6.0 秒 / 長文 12.0 秒、読み込み後 831 MB、メモリ警告なし（ビルド 5、測定 2）
- [x] V1→V2 のストアがビルド 5 で開けた（暗黙の確認。既存メモありの移行は下記で未検証）

### 実機で未検証
- [ ] 日誌 3 タブ UI
- [ ] 収録 → 自動要約 → 保存
- [ ] 手動の「要約する」
- [ ] 質問: 「先週」／キーワード／ヒット無し（直近 10 件フォールバック表示）
- [ ] 機内モード（AT-02 / AT-14、G4）
- [ ] 要約中・回答中のバックグラウンド（生成が止まるか）
- [ ] 初回の自動読み込み中にバックグラウンド（修正済み・実機未検証）
- [ ] メモリ警告による生成中の停止
- [ ] 破棄確認ダイアログと下スワイプの無効化
- [ ] 既存メモがある状態での実際の NoteRecord 移行
- [ ] GitHub への実送信（トークン権限、private 判定、ラベル 422）
- [ ] 要約本文の品質（短文の見出しが本文の書き出しになりがち）
- [ ] 実機での MLX 読み込みのキャンセル、読み込み済みモデル削除との整合

### バックログ（Phase 2 で見送った小さな問題・新しい順）
- 最終: `RelativeDateRange` にひらがな「おととい」がない
- Task 9: `deleteError` が次の削除成功まで残る／短文でもモデル未選択時に「要約する」節が出る
- Task 6d: 長い状態文が 40 字で切れる／モデル切替で結果が消えない／テストに空タイトル・tok/s なしが無い／行の密度は実機確認
- Task 6b: 音声可否を表示のたびに記録／本文プレビューに改行が入り得る／コピー済みフラグが戻らない／削除失敗でも削除を記録／`.preparing` 中の停止で空結果行／壊れたログ読み込みのテストなし
- Task 6: 停止で生成中の `generate` を止められない／`NetworkCostProbe` の再初期化／読み込み済みモデルの削除がランタイムと未調整／インストールの二重タップ／到達しない `.needsConfirmation` 分岐
- Task 5: `stop()` が `.preparing` 中に無視される／オーディオセッション中断の扱いなし／`AssetInventory.reserve` が要る可能性／`stop()` と `.failed` の狭い競合／古い consume タスクが即再開を中断し得る
- Task 4: 複数シャードの一部だけでも `isDownloaded` が true／失敗・置換された読み込み後に `clearCache` が走らない／テスト内の未 await のキャンセル
- Task 3: `SearchTerms.parse` が末尾 `]` の文章で失敗（安全に代替）／`shouldSummarize` が未トリムの文字数を数える／代替→選択の結合テストなし／パッカーの上限ちょうどのテストなし
- Task 7: `ask()` は回答ストリームを消費する前にモデルを起動する／「先週」テストに検索語代替のパスなし／範囲フィルタが冗長／`all()` は空判定のみ（`recent(limit:1)` が望ましい）／検索語の上限が 5（プロンプト）と 8（パーサ）で不一致
- Task 8: 移行エラーのログが debug レベル／ストアのインスタンス間で sequence が重複し得る
- Task 2: `JournalNoteStore` の delete / deleteAll が actor 跨ぎで非原子的／射影はタイトルを付けない
- Task 1: `ios-ci.yml` の実機ビルド手順が 1 行にまとめられている（見た目のみ）
- 保留（修正中）: 日誌の初回自動読み込み中のバックグラウンド（上記の未検証項目）
- 保留: 測定ログは「全データ削除」で消えるが、バックアップ除外の実機確認なし

## モデル階層とダウンロードモデルのチャット（ADR-031）
計画: `docs/superpowers/plans/2026-10-20-model-hierarchy-mlx-chat.md`

### 実機で未検証（iPhone 15）
- [ ] 設定の階層（クラウド／ローカル: Apple・ダウンロードモデル）の表示と選択、Apple 不可時の無効表示
- [ ] 既定モデルの移行（キー無し→ダウンロードモデル、キー有り→Claude のまま）
- [ ] Qwen2.5 でのチャット往復（逐次表示、「モデルを読み込み中…」）と機内モードでの往復
- [ ] 停止・バックグラウンド・メモリ解放で途中の返答が保存されないこと
- [ ] 未ダウンロード時の理由表示と「設定でダウンロードする」リンク
- [ ] ダウンロード確認ダイアログがアプリ直下の 1 か所から、設定・モデル管理画面の上に表示されること
- [ ] キーボードの「完了」とスクロールでの閉じ
- [ ] 日誌タブ: Apple 選択（iPhone 15 では不可）で「Apple は使えないため、ダウンロードモデルを使います」が出て、ダウンロードモデルで要約・質問できる（ADR-032）
- [ ] 日誌タブの Apple 経路（要約・「日誌に聞く」、1500 字が文脈に収まるか）— Apple Intelligence 対応端末が必要

### バックログ
- ダウンロード後も「設定でダウンロードする」リンクが次の送信まで残る
- 1 回の返答中にメモリ解放→再読み込みされた場合は検出しない
- `ModelSettings` の移行でキー読み出し失敗時のログなし（次回起動で再試行）

## 会議モード（リアルタイム文字起こし + 随時要点、ADR-033/034）
設計: `docs/superpowers/specs/2026-10-19-meeting-mode-design.md` / 計画: `docs/superpowers/plans/2026-10-19-meeting-mode.md`

### 実装済み（CI で自動テスト合格）
- Core: `TranscriptSegment`、`MeetingTranscriptFormatter`（`[mm:ss]`／`h:mm:ss`）、`MeetingNotesPolicy`（300 文字・60 秒）、`MeetingTitle`
- Runtime: `JournalAssisting.updateMeetingNotes(previous:newText:)` と `JournalPrompts.meetingNotes*`（3 見出し固定）
- App: `TranscriptSource` / `TranscriptEvent`、`SpeechCapture` の確定セグメントのイベントストリームと割り込み検知、`MeetingSession`、「会議」タブ（`MeetingView`）、`UIBackgroundModes: audio`

### 実機で未検証（iPhone 15）
- [ ] ロック中・ポケット内で文字起こしが続くこと（バックグラウンド audio）
- [ ] 電話割り込み → 「再開」で続きが録れること
- [ ] 1 時間連続（SpeechAnalyzer のメモリ・精度、端末の発熱）
- [ ] 要点の品質（3 見出し固定を 1.5B / Apple が守るか）、300 文字・60 秒の閾値の体感
- [ ] 前面復帰で未反映分が 1 回で追いつくこと、更新中の「停止」
- [ ] 録音中のモデル読み込みでメモリ警告が出ないこと（音声 + MLX の同居）
- [ ] 終了 → 日誌に「会議 M/d HH:mm」で保存され、「聞く」から検索できること
- [ ] `SpeechTranscriber.Result.range` の秒が録音開始基準で取れること（取れなければ受信時刻で代替している）

### バックログ（初版で見送り）
- 割り込み終了時の自動再開、イヤホン抜き差し（route change）
- ユーザーが上にスクロール中の自動追従の抑止（初版は常に末尾へ）
- 要点テンプレートの選択、同時翻訳（次ステップ）
