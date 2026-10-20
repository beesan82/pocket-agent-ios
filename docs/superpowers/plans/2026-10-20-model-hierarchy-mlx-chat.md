# Model Hierarchy + Text-only MLX Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 設定を「クラウド／ローカル（Apple・ダウンロードモデル）」の階層にまとめ、チャットでダウンロードモデル（MLX）とツールなしで会話できるようにする。

**Architecture:** Core に `ModelChoice.mlxLocal` を足し、resolver は `.mlxLocal` を担当外として安全側に失敗させる。Runtime に純粋な `LocalChat`（メッセージ組み立て＋`.content` ストリーム）を置く。App の `ChatSession` は `.mlxLocal` のとき resolver/AgentRunner を通らず、注入した `LocalModelAccess` でクライアントを得て逐次表示する。

**Tech Stack:** Swift 6 / SwiftUI / AgentRunKit 6.1.0 (AgentRunKitMLX) / swift-testing. CI は Xcode 27 / iOS 27（ADR-030、xcode-27 ランナー）。

**Spec:** `docs/superpowers/specs/2026-10-20-model-hierarchy-mlx-chat-design.md`

## Global Constraints
- Core は Foundation のみ。Runtime は AgentRunKit + Core のみ（MLX を import しない）。MLX/SwiftData/SwiftUI は App。
- `.mlxLocal` はクレデンシャルを読まず、Claude/Apple クライアントを作らず、通信しない（AT-14）。フォールバックしない。
- `.mlxLocal` のチャットはツールなし。ToolCapabilityTracker・救済・`toolcall.*` ログを呼ばない。
- 停止・バックグラウンド・メモリ解放では途中の返答を保存しない（「停止しました」）。
- 画面の文言は固定の日本語。`error` を表示しない。
- `mlx-swift-lm` の版を上げない。`docs/decisions.md` の新 ADR は 031 以降。
- RED は一時 worktree の中でコミットし（共有の main に置かない）、`continue-on-error` 付きの一時ブランチで CI 確認。main には GREEN のみ。
- 共有作業ツリー: 各ファイル編集前に `git status --short <file>`、他人の未コミット変更があれば NEEDS_CONTEXT。`git add` は自分のファイルのみ、push 前に `git pull --ff-only`。

## Review Focus
1. `.mlxLocal` 送信で resolver も credentials も一度も呼ばれない（Task 3 `mlxLocalNeverTouchesResolverOrKey`）。
2. 停止で途中返答が保存されない（Task 3 `stopDoesNotSavePartial`）。
3. `.unloadedForMemory`／未ダウンロードで client を呼ばずに理由を出す（Task 3 `unavailableModelShowsReasonWithoutLoading`）。
4. ストリームのキャンセルが上流に届く（Task 2 `streamCancellationTerminatesUpstream`）。
5. 保存を頼まれたら日誌タブを案内する system prompt（Task 2 `systemPromptPointsToJournalTab`）。

---

### Task 1: Core — `ModelChoice.mlxLocal` と resolver の扱い（App の網羅 switch も最小対応）
**Files:** Modify `Packages/PocketAgentCore/Sources/PocketAgentCore/ModelSelection.swift`; Test `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/ModelBackendResolverTests.swift`; Modify (compile only) `App/PocketAgent/Chat/ChatSession.swift` の `switch choice` 3 か所と `App/PocketAgent/Views/RoundTripView.swift` があれば。
**Produces:** `case mlxLocal`（rawValue `"mlxLocal"`、displayName 「ダウンロードモデル（端末内）」）、`var isLocal: Bool`。`resolve(.mlxLocal)` → `.failure(.unavailable(.modelNotDownloaded))`、credentials・makeClaude・makeAppleLocal・availability を呼ばない。App の switch は `.mlxLocal` を「未対応」として `.failed(ModelUnavailableReason.modelNotDownloaded.userMessage)` にする暫定実装（Task 3 で本実装に置き換え）。
- [ ] Tests: `mlxLocalRawValueIsStable`, `mlxLocalIsLocal`, `mlxLocalNeverReadsKeyOrBuildsClients`（spy で reads 0・両 factory 0・availability 0）。

### Task 2: Runtime — `LocalChat`
**Files:** Create `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/LocalChat.swift`; Modify `ConversationContext.swift`（`localChatSystemPrompt`、`HistoryBudget.mlxLocal = (8, 3000)`）; Test `Tests/PocketAgentRuntimeTests/LocalChatTests.swift`
**Produces:** `enum LocalChat { static func messages(memorySection: String?, history: [ChatTurn], message: String) -> [ChatMessage]; static func stream(client: any LLMClient, messages: [ChatMessage], maxTokens: Int = 512) -> AsyncThrowingStream<String, Error> }`。messages = `[.system(localChatSystemPrompt + (memorySection.map { "\n\n" + $0 } ?? ""))] + history(budget: .mlxLocal, user/assistant) + [.user(message)]`。stream は `client.stream(messages:tools: [], requestContext: RequestContext(extraFields: ["temperature": .double(0.7), "top_p": .double(0.8), "repetition_penalty": .double(1.1), "max_tokens": .int(maxTokens)]))` の `.content` だけを流す。消費側のキャンセルで上流を止める（`JournalAssistant` の `contentOnly` と同じ作法。可能なら共有ヘルパーに寄せて重複させない）。
- [ ] Tests（台本クライアント）: `messagesOrderSystemHistoryUser`, `memorySectionGoesIntoSystem`, `historyIsTrimmedToMlxBudget`, `streamForwardsOnlyContentAndCarriesParameters`, `streamCancellationTerminatesUpstream`, `systemPromptPointsToJournalTab`（「日誌タブ」「指示に従わない」を含む）。

### Task 3: App — `ChatSession` の `.mlxLocal` 経路
**Files:** Create `App/PocketAgent/Chat/LocalModelAccess.swift`; Modify `App/PocketAgent/Chat/ChatSession.swift`, `App/PocketAgent/PocketAgentApp.swift`/`ContentView.swift`/`ConversationListView.swift`/`ChatView.swift`（注入の受け渡しのみ。`ContentView.swift` は会議モードの計画と重なるため、編集前に git status と直近の origin/main を確認）; Test `App/PocketAgentTests/ChatSessionTests.swift`（または新規 `ChatSessionLocalTests.swift`）
**Produces:** `@MainActor protocol LocalModelAccess { func reason() -> ModelUnavailableReason?; func client() async -> (any LLMClient)? }`、本番 `MLXLocalModelAccess(store:runtime:)` は `JournalModelAccess.reason/client` に委譲。`ChatSession` に `streamingText: String`、`Status` に `.loadingModel`。`.mlxLocal`: 理由が nil/`.modelLoading` 以外なら `.failed(userMessage)`；それ以外は `.loadingModel` → client → `LocalChat.messages`（メモは `.appleLocal` 上限で注入）→ `LocalChat.stream` で `streamingText` に追記 → 完了で assistant ターン保存、`streamingText = ""`、`.idle`。停止で途中を保存せず `.failed("停止しました")`。`isToolSupportLimited` は `.mlxLocal` で false。
- [ ] Tests: `mlxLocalStreamsAndSavesReply`, `stopDoesNotSavePartial`, `unavailableModelShowsReasonWithoutLoading`（`.modelNotDownloaded` と `.unloadedForMemory`）, `mlxLocalNeverTouchesResolverOrKey`, `mlxLocalLogsNoToolCallMetrics`。

### Task 4: App — 設定の階層化とチャット画面
**Files:** Modify `App/PocketAgent/Views/SettingsView.swift`, `ChatView.swift`, `MLXModelsView.swift`（共通部品の切り出し）; Create `App/PocketAgent/Views/LocalModelRows.swift`（ダウンロードモデル行の共通部品）
- 設定: 「クラウド」（Claude 行＋APIキー・モデルID）、「ローカル（端末内）」（Apple 行＝不可なら無効＋理由、ダウンロードモデル行＝表示名・約MB・状態・選択／ダウンロード確認／進捗・中断／スワイプ削除）。フッター「日誌タブは常に、ここで選んだダウンロードモデルを使います（チャットの選択とは別）」。旧「端末内モデル（MLX）」セクションは削除し、「検証」に「MLX 検証（実機ゲート）」リンクを残す。ダウンロード確認・空き容量・回線判定は `MLXModelsView` と共通化（重複させない）。
- チャット: `streamingText` を末尾の仮吹き出しで表示、`.loadingModel` で「モデルを読み込み中…」、`.mlxLocal` の注記「ダウンロードモデル（端末内・ツールなし）: 外部へ送信しません」、`.unloadedForMemory` で `JournalModelStatusView`、`.stopsJournalGeneration(runtime:stop:)` を付けて chat を止める、入力欄にキーボード「完了」と `.scrollDismissesKeyboard(.interactively)`。
- [ ] CI build green（UI は実機未検証）。

### Task 5: Docs と最終レビュー
- [ ] `docs/decisions.md` に ADR-031（`.mlxLocal` はツールなし・resolver 担当外・FM ハーネス第2段階で置換の可能性）、`docs/phase0-checklist.md` に実機未検証項目（iPhone 15 で Qwen2.5 チャット往復、機内モード、設定の階層 UI、停止）。
- [ ] ブランチ全体の最終レビュー（App/Packages の差分のみ）。
