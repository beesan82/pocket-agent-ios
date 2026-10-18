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
- [ ] Apple ローカルでの複数ターンとツール呼び出し（畳み込みプロンプトは fake でのみ確認、ADR-017）
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
