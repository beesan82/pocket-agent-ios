# Phase 2 MLX Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone 15 の端末内 LLM（MLX）で、音声・テキストの日誌を要約して残し、日誌を根拠に質問へ答えるアプリにする。

**Architecture:** 日誌データと検索・日付・詰め込み・解析の純粋ロジックは Core。LLM を使う 2 段階パイプライン（検索語抽出 → アプリ検索 → 回答）と要約は Runtime の `JournalAssistant`（`any LLMClient` だけに依存し、MLX を import しない）。MLX の読み込み・ダウンロード・メモリ・音声入力・画面は App。MLX は `AgentRunner` を通さず `generate`/`stream` を直接呼ぶ。

**Tech Stack:** Swift 6 / SwiftUI / SwiftData (VersionedSchema) / AgentRunKit 6.1.0 + AgentRunKitMLX / mlx-swift 0.30.6 / mlx-swift-lm 2.30.6 / Speech (SpeechAnalyzer, iOS 26) / AVFoundation / swift-testing

**Spec:** `docs/superpowers/specs/2026-10-18-phase2-mlx-journal-design.md`

## Global Constraints
- Core は Foundation のみ。Runtime は AgentRunKit + Core のみ（**AgentRunKitMLX / MLX を import しない**）。MLX・Speech・SwiftData は App だけ。
- MLX クライアントは `AgentRunner`/`Agent` に渡さない（`ContentOnlyTerminatingClient` 非準拠のため）。`client.generate` / `client.stream` を 1 往復ずつ直接呼ぶ。
- `#if targetEnvironment(simulator)` で MLX の実行経路を完全に迂回する。シミュレータでは `ModelUnavailableReason.simulatorUnsupported` を返し、MLX の API を一切呼ばない。CI のシミュレータ build/test は緑のまま。
- ダウンロードはユーザーのタップでのみ開始。開始前にサイズ・ライセンス・「通信が発生します」を表示。空き容量 < サイズ×1.5 なら開始しない。モバイル回線では確認を挟む。
- 日誌の本文・質問は Anthropic へ送らない。Claude のメモツールが読めるのは `origin == .noteTool` の項目だけ。
- 原文の保存は常に可能（モデルや要約の失敗で保存を止めない）。回答には根拠の日誌を必ず併記。
- 画面に出す失敗文言は固定文のみ。`error` 本体は表示しない。
- 文言は日本語。既定モデル `mlx-community/Qwen2.5-1.5B-Instruct-4bit`（revision `main`、約 869MB、Apache-2.0）。要約の自動実行閾値 200 文字。詰め込み上限 20 件・各 300 文字・合計 3000 文字。`GenerateParameters(temperature: 0.7, topP: 0.8, repetitionPenalty: 1.1)`、maxTokens 要約 512 / 回答 384 / 検索語 64。
- RED は一時ブランチ（`continue-on-error`）で確認し、main には GREEN だけ push する（メモリ `red-runs-off-main`）。
- 実機ゲート（Task 6 の TestFlight）までは、モデル固有のプロンプト文言・パラメータは「暫定」。ゲート結果が出るまで Task 7〜9 はモデル非依存の部分だけ進め、文言の確定は Task 10 で行う。

## Review Focus
1. 「先週なにしてた？」で検索語が 1 件も当たらない → 先週の全件で答える（Task 3 `dateRangeWithNoTermHitsUsesWholeRange`）。
2. 日誌 0 件 → LLM を呼ばず「日誌がまだありません」（Task 7 `emptyJournalNeverCallsModel`）。
3. 要約ストリーム途中で停止 → 原文は保存できる、要約は破棄（Task 9 の `JournalCaptureSession` テスト `stopDuringSummaryKeepsTranscript`）。
4. メモリ警告 → モデル解放 + 固定文言、再読み込みで復帰（Task 4 `memoryWarningUnloadsAndExplains`）。
5. Claude の `list_notes` に音声日誌が混ざらない（Task 2 `noteProjectionHidesJournalEntries`）。

---

### Task 1: AgentRunKitMLX をリンクし、CI に実機向け無署名ビルドを追加
**Files:** Modify `project.yml`, `.github/workflows/ios-ci.yml`, `App/PocketAgent/Adapters/SDKLinkCheck.swift`; Test `App/PocketAgentTests/SDKLinkCheckTests.swift`

**Produces:** app ターゲットが `AgentRunKitMLX`（package AgentRunKit）と `MLX`（package `https://github.com/ml-explore/mlx-swift.git` exactVersion `0.30.6`、`Packages/PocketAgentRuntime/Package.resolved` の revision と一致）をリンクする。`SDKLinkCheck.mlxClientTypeName: String`（`String(describing: MLXClient.self)`）。

- [ ] Test: `mlxClientIsLinked`（`mlxClientTypeName.contains("MLXClient")`）。
- [ ] CI: 「Build (iOS Simulator, unsigned)」の後に「Build (iOS device, unsigned)」= `xcodebuild build -project PocketAgent.xcodeproj -scheme PocketAgent -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO | tee build-device.log`、artifact に `build-device.log` を追加。pins-drift チェックは mlx-swift を含めて一致すること。
- [ ] GREEN を確認。シミュレータ側のビルドが MLX のリンクで失敗したら BLOCKED で報告（controller が裁定）。

### Task 2: Core — JournalEntry / JournalStore / Note 射影 / 可否理由の追加
**Files:** Create `Packages/PocketAgentCore/Sources/PocketAgentCore/Journal.swift`; Modify `ModelSelection.swift`; Test `Tests/PocketAgentCoreTests/JournalStoreTests.swift`, `ModelBackendResolverTests.swift`（理由の文言テストに追加）

**Produces:**
- `struct JournalEntry: Sendable, Equatable, Identifiable { let id: UUID; let createdAt: Date; let source: Source; let origin: Origin; let body: String; let transcript: String?; let title: String?; enum Source: String, Sendable, Codable { case voice, text }; enum Origin: String, Sendable, Codable { case journal, noteTool } }` + `init(id: UUID = UUID(), createdAt: Date, source:, origin:, body:, transcript: String? = nil, title: String? = nil)`
- `struct NewJournalEntry: Sendable { source, origin, body, transcript, title }`（add の入力）
- `protocol JournalStore: Sendable { func add(_ entry: NewJournalEntry) async throws -> JournalEntry; func all() async throws -> [JournalEntry]; func search(_ query: String) async throws -> [JournalEntry]; func entries(in interval: DateInterval) async throws -> [JournalEntry]; func recent(limit: Int) async throws -> [JournalEntry]; func entry(id: UUID) async throws -> JournalEntry?; func delete(id: UUID) async throws -> Bool; func deleteAll() async throws }` — 並びは新しい順。`search` は `NoteSearch.matches(body + "\n" + (title ?? ""), query:)`。
- `actor InMemoryJournalStore: JournalStore { init(now: @Sendable () -> Date = Date.init) }`
- `struct JournalNoteStore: NoteStore { init(journal: any JournalStore) }` — `add` は `origin: .noteTool, source: .text`、`all/search/note/delete` は `.noteTool` の項目だけ対象、`deleteAll` は `.noteTool` だけ削除。`Note(id:text: body, createdAt:)` に射影。
- `ModelUnavailableReason` に追加: `simulatorUnsupported`, `modelNotDownloaded`, `modelLoading`, `insufficientDiskSpace(requiredBytes: Int64)`, `unloadedForMemory`。`userMessage` は固定日本語（例: 「シミュレータでは端末内モデルを利用できません」「モデルが未ダウンロードです。設定のモデル管理からダウンロードしてください」「モデルを読み込み中です」「空き容量が不足しています（必要: 約 X GB）」「メモリ不足のためモデルを解放しました。もう一度読み込んでください」）。

- [ ] Tests: `addListsNewestFirst`, `entriesInIntervalIsInclusiveStartExclusiveEnd`, `recentLimits`, `searchLooksAtTitleAndBody`, `noteProjectionHidesJournalEntries`（journal 2 件 + noteTool 1 件 → `all()` が 1 件、`delete` で journal 項目は消せない、`deleteAll` 後も journal 2 件残る）, `noteProjectionAddsAsNoteTool`, `newReasonsExplainThemselves`。

### Task 3: Core — 検索条件・詰め込み・解析の純粋関数
**Files:** Create `Packages/PocketAgentCore/Sources/PocketAgentCore/JournalQuery.swift`, `JournalPolicies.swift`; Test `JournalQueryTests.swift`, `JournalPoliciesTests.swift`

**Produces:**
- `enum RelativeDateRange { static func parse(_ question: String, now: Date, calendar: Calendar) -> DateInterval? }` — 今日／昨日／今週／先週／今月／先月（先に出現した語を採用。週は `calendar.firstWeekday`）。
- `enum SearchTerms { static func parse(llmOutput: String) -> [String]?（JSON 配列の文字列のみ、trim、空除去、最大 8。配列でなければ nil）; static func fallback(question: String) -> [String]（空白と 、。？！?! で分割、2 文字以上、重複除去） }`
- `enum JournalRetrieval { static func select(inRange: [JournalEntry]?, hitsByTerm: [[JournalEntry]], recent: [JournalEntry]) -> (entries: [JournalEntry], usedRecentFallback: Bool) }` — `inRange` あり: 範囲内で term に 1 件でも当たれば当たった項目だけ、なければ範囲全件。`inRange` なし: hits の和集合（id で重複除去）。どちらも 0 件なら `recent` と `usedRecentFallback = true`。結果は新しい順。
- `struct PackedEntry: Equatable { let entry: JournalEntry; let text: String }`、`enum JournalContextPacker { static func pack(_ entries: [JournalEntry], maxEntries: Int = 20, maxCharactersPerEntry: Int = 300, maxTotalCharacters: Int = 3000) -> [PackedEntry] }`
- `struct SummaryOutput: Equatable { let title: String?; let body: String }`、`enum SummaryParser { static func parse(_ output: String) -> SummaryOutput }` — 1 行目が `見出し:`/`見出し：` で始まれば見出し（15 文字で切る）、残りが本文。なければ全文が本文。
- `enum SummaryPolicy { static let autoSummarizeThreshold = 200; static func shouldSummarize(text: String, modelReady: Bool) -> Bool }`
- `enum DiskSpaceRule { static func canDownload(modelBytes: Int64, freeBytes: Int64) -> Bool }`（free ≥ 1.5 × model）

- [ ] Tests: 日付 6 語 + 該当なし + 週の境界（月曜始まり固定 Calendar で検証）; `parseAcceptsOnlyStringArrays`（`["a","b"]` → 2 件、`{"a":1}` → nil、`[]` → 空）; `fallbackSplitsOnJapanesePunctuation`（「先週の会議、どうなった？」→ ["先週の会議","どうなった"]）; `dateRangeWithNoTermHitsUsesWholeRange`; `termsNarrowWithinRange`; `noRangeUnionsHits`; `emptyEverythingFallsBackToRecent`; `packRespectsAllThreeLimits`; `parseTitleLine`（全角コロン、長い見出し）; `thresholdIs200Chars`（199/200 境界、modelReady false は常に false）; `diskRuleBoundary`。

### Task 4: App — MLX モデル管理とランタイム
**Files:** Create `App/PocketAgent/MLX/MLXModelRegistry.swift`, `MLXModelStore.swift`, `MLXRuntime.swift`, `MLXAvailability.swift`; Test `App/PocketAgentTests/MLXModelStoreTests.swift`, `MLXRuntimeTests.swift`

**Produces:**
- `struct MLXModelInfo: Identifiable, Sendable { let id: String（repo id）; let displayName: String; let revision: String; let approxBytes: Int64; let license: String; let notes: String }`、`enum MLXModelRegistry { static let `default` = qwen25_1_5B; static let all: [MLXModelInfo] }`（Qwen2.5-1.5B-Instruct-4bit, Qwen3-1.7B-4bit は notes に「thinking 無効化が未確認のため候補のみ」）。
- `protocol ModelDownloading: Sendable { func download(_ model: MLXModelInfo, to base: URL, progress: @Sendable (Double) -> Void) async throws; func isDownloaded(_ model: MLXModelInfo, at base: URL) -> Bool; func delete(_ model: MLXModelInfo, at base: URL) throws }`。本物 `HubModelDownloader`（`HubApi(downloadBase: base).snapshot(from: Repo(id:), revision:, progressHandler:)`、`isDownloaded` = `base/models/<id>` に `config.json` と 1 つ以上の `.safetensors`）。保存先 `MLXModelStore.baseDirectory` = Application Support/Models。
- `@MainActor @Observable final class MLXModelStore { enum Status: Equatable { case notDownloaded, downloading(Double), downloaded, failed(String) }; var selected: MLXModelInfo; func status(of:) -> Status; func startDownload(_:, freeBytes: Int64, isExpensiveNetwork: Bool) → `.needsConfirmation(reason)`/開始; func cancelDownload(); func delete(_:) ; init(downloader:, baseDirectory:, defaults:) }` — 選択モデルは UserDefaults `pocketagent.mlxModel`。
- `@MainActor @Observable final class MLXRuntime { enum State: Equatable { case idle, loading, loaded, unloadedForMemory, failed(String) }; var client: (any LLMClient)?; var lastLoadSeconds: Double?; func load(_ model: MLXModelInfo) async; func unload(); init(store:, loader: any ModelLoading) }` — `ModelLoading` プロトコル（本物: `loadModelContainer(hub:configuration: ModelConfiguration(id:revision:), progressHandler:)` → `MLXClient(container:model:parameters:)`。読み込み時 `Memory.cacheLimit = 64 * 1024 * 1024`。`unload` は client を nil にして `Memory.clearCache()`）。`UIApplication.didReceiveMemoryWarningNotification` で `unload()` → `.unloadedForMemory`。
- `enum MLXAvailability { static func reason(state: MLXRuntime.State, status: MLXModelStore.Status) -> ModelUnavailableReason? }`（simulator → `.simulatorUnsupported` を最優先）。
- `#if targetEnvironment(simulator)` では `HubModelDownloader`/本物ローダーの本体を `fatalError` ではなく `throw` にし、画面側は `reason` で止める。

- [ ] Tests（fake downloader/loader）: `downloadRefusedWhenDiskTooSmall`, `expensiveNetworkNeedsConfirmation`, `downloadProgressAndCompletion`, `cancelLeavesNotDownloaded`, `deleteResetsStatus`, `loadSetsClientAndSeconds`, `memoryWarningUnloadsAndExplains`（通知投稿 → `.unloadedForMemory`、`client == nil`、`MLXAvailability.reason` が `.unloadedForMemory`）, `simulatorReasonWinsOnSimulator`（`#if targetEnvironment(simulator)` 内でのみ実行）。

### Task 5: App — 音声入力（SpeechAnalyzer）
**Files:** Create `App/PocketAgent/Speech/SpeechCapture.swift`, `SpeechAvailability.swift`; Modify `project.yml`（`INFOPLIST_KEY_NSMicrophoneUsageDescription: 日誌を音声で記録するためにマイクを使用します`, `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription: 録音した音声を端末内で文字に起こすために使用します`）; Test `App/PocketAgentTests/SpeechAvailabilityTests.swift`

**Produces:**
- `enum SpeechUnavailableReason: Equatable { case moduleUnavailable, japaneseUnsupported, assetsNotInstalled, permissionDenied; var userMessage: String }`
- `enum SpeechAvailability { static func reason(isAvailable: Bool, supportsJapanese: Bool, assetsInstalled: Bool, permissionGranted: Bool) -> SpeechUnavailableReason? }`（この順で最初の不成立を返す）
- `@MainActor @Observable final class SpeechCapture { enum State: Equatable { case idle, preparing, recording, finishing, failed(String) }; var volatileText: String; var finalText: String; var reason: SpeechUnavailableReason?; func refreshAvailability() async; func requestPermissions() async; func installAssets() async throws; func start() async throws; func stop() async }` — `AVAudioEngine` 入力 → `AnalyzerInput` ストリーム → `SpeechAnalyzer` + `SpeechTranscriber(locale: ja_JP, preset: .transcription)`。`isAvailable` / `supportedLocales` / `installedLocales` / `AssetInventory.assetInstallationRequest(supporting:)` を使う。`installAssets` はユーザー操作からのみ呼ぶ。

- [ ] Tests: `reasonOrder`（4 通りの最初の不成立）, `allGoodGivesNil`。実装はビルドのみ（実機未検証と記録）。

### Task 6: App — モデル管理画面と検証画面 → TestFlight（Phase 2-0 ゲート）
**Files:** Create `App/PocketAgent/Views/MLXModelsView.swift`, `MLXValidationView.swift`, `docs/phase2-mlx-eval.md`（記入テンプレート）; Modify `SettingsView.swift`（「モデル管理」「検証 → MLX 検証」リンク）, `PocketAgentApp.swift`（`MLXModelStore`/`MLXRuntime` を 1 個ずつ生成して環境に流す）

- MLXModelsView: 候補一覧、各行に表示名・サイズ・ライセンス・状態、「ダウンロード」（確認ダイアログ: サイズ・ライセンス・「通信が発生します」。モバイル回線なら「Wi-Fi を推奨」）、進捗と「中断」、「削除」、選択。
- MLXValidationView: 「読み込む／解放」、`lastLoadSeconds`、`Memory.activeMemory` と `os_proc_available_memory()` を MB 表示、3 サンプル（短文・300 字・1000 字の固定日本語テキスト）それぞれに「要約」ボタン → `client.generate` 直接呼び出し（Task 3 の `SummaryParser`、暫定プロンプトはこの画面内の定数）→ 本文・所要秒・tokens/s（`AssistantMessage.tokenUsage` の output / 秒）。音声: `SpeechCapture` の可否理由、「アセットを導入」、「30 秒テスト」（録音 → 文字起こし表示）。すべて固定文言、`error` 非表示。
- [ ] GitHub CI 緑 → Codemagic「iOS TestFlight」を**ユーザーが**起動 → ユーザーが iPhone 15 で測定し、数値と品質（3 段階）を報告。Claude が `docs/phase2-mlx-eval.md` に記入し、既定モデルを確定（ADR）。**ここで一旦停止し、ゲート結果を待つ。**

### Task 7: Runtime — JournalAssistant（要約・2 段階の聞くパイプライン）
**Files:** Create `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/JournalAssistant.swift`, `JournalPrompts.swift`; Test `Tests/PocketAgentRuntimeTests/JournalAssistantTests.swift`, `ScriptedTextClient.swift`

**Produces:**
- `enum JournalPrompts { static let summarySystem: String; static func summaryUser(text:) -> String; static let termsSystem: String; static func termsUser(question:) -> String; static let answerSystem: String; static func answerUser(question:, packed: [PackedEntry], usedRecentFallback: Bool) -> String }`（日誌は `--- 日誌 (yyyy-MM-dd) ---` 区切り、`usedRecentFallback` なら「直近の日誌から」と断る指示を含む）。
- `protocol JournalAssisting: Sendable { func summarize(_ text: String) -> AsyncThrowingStream<String, Error>; func ask(_ question: String, store: any JournalStore) async throws -> AskResult }`（App のテストが fake を差すための口）
- `struct JournalAssistant: JournalAssisting { init(client: any LLMClient, now: @Sendable () -> Date = Date.init, calendar: Calendar = .current) }` — `summarize` は `client.stream` の `.content(String)` デルタだけを流す（他のケースは無視）。`ask` は下記。
- `struct AskResult { let evidence: [PackedEntry]; let usedRecentFallback: Bool; let answer: AsyncThrowingStream<String, Error> }`。`ask` の手順: `store.all()` が空 → `AskResult(evidence: [], answer: 「日誌がまだありません」の 1 チャンク)` で LLM 不呼出。日付範囲 `RelativeDateRange.parse`。検索語 = `client.generate`（maxTokens 64）→ `SearchTerms.parse` ?? `fallback`。`inRange = range.map { store.entries(in:) }`、`hitsByTerm = terms.map { store.search }`（range ありなら range 内に限定）、`recent = store.recent(limit: 10)` → `JournalRetrieval.select` → `JournalContextPacker.pack` → `client.stream`。
- 生成パラメータは `RequestContext(extraFields: ["temperature": .double(0.7), "top_p": .double(0.8), "max_tokens": .int(N), "repetition_penalty": .double(1.1)])` で渡す（`RequestContext.init` に `extraFields` あり、`MLXMessageMapper.mergeParameters` がこのキーを読む。いずれもソース確認済み）。

- [ ] Tests（`ScriptedTextClient`: `generate` と `stream` に台本で応える、受け取った messages/requestContext を記録）: `emptyJournalNeverCallsModel`, `termsFromJSONAreUsed`, `brokenJSONFallsBackToQuestionFragments`, `dateQuestionUsesRangeEvenWithoutHits`, `answerPromptContainsEvidenceOnly`（詰め込み上限内、`http`/`sk-` を含まない）, `recentFallbackIsDeclared`, `summaryStreamsDeltas`, `cancellationStopsStreams`, `requestContextCarriesLimits`（max_tokens 64/384/512）。

### Task 8: App — SwiftData 日誌・VersionedSchema・メモ移行
**Files:** Create `App/PocketAgent/Persistence/JournalSchema.swift`（`SchemaV1`=現行 3 モデル, `SchemaV2`=+`JournalEntryRecord`, `PocketAgentMigrationPlan`）, `SwiftDataJournalStore.swift`, `NoteMigration.swift`; Modify `Models.swift`（`AppModelContainer.make` が `migrationPlan` を使う）, `ConversationRepository.swift`（`DataReset.eraseAll` が journal も消す）, `ChatSession.swift`/`PocketAgentApp.swift`/`SettingsView.swift`（`SwiftDataNoteStore` の利用箇所を `JournalNoteStore(journal: SwiftDataJournalStore(...))` に置換）; Delete `SwiftDataNoteStore.swift` は**移行完了後の Task 10 まで残す**; Test `App/PocketAgentTests/JournalPersistenceTests.swift`

**Produces:** `JournalEntryRecord { id, createdAt, sourceRaw, originRaw, body, transcript?, title? }`、`@ModelActor actor SwiftDataJournalStore: JournalStore`、`enum NoteMigration { @MainActor static func migrateOnce(context: ModelContext, defaults: UserDefaults) throws }`（`pocketagent.notesMigrated` が false のとき NoteRecord → JournalEntryRecord(.text, .noteTool, 同じ createdAt) を全件コピー → save → NoteRecord を削除 → save → flag true。途中で throw したら rollback し flag は立てない）。
- [ ] Tests: `crudAndNewestFirst`, `entriesInRange`, `searchMatchesTitle`, `migrationCopiesAndDeletesOnce`（2 回目は何もしない）, `migrationFailureKeepsNotes`（save を失敗させる fake は難しければ、flag 未設定なら再実行されることだけ検証し報告）, `eraseAllRemovesJournal`, `noteToolsSeeOnlyNoteToolEntries`（SwiftData 版の射影）。

### Task 9: App — 日誌・聞く・タブ構成の画面
**Files:** Create `App/PocketAgent/Journal/JournalCaptureSession.swift`, `App/PocketAgent/Journal/AskSession.swift`, `App/PocketAgent/Views/RootTabView.swift`, `JournalView.swift`, `JournalCaptureView.swift`, `AskJournalView.swift`; Modify `ContentView.swift`（`RootTabView` を返す）, `ConversationListView.swift`（「メモ」リンクを外す）; Delete `NotesView.swift`; Test `App/PocketAgentTests/JournalCaptureSessionTests.swift`, `AskSessionTests.swift`

**Produces:**
- `@MainActor @Observable final class JournalCaptureSession { enum Phase: Equatable { case editing, summarizing, summarized, saving, saved, failed(String) }; var transcript: String; var summaryBody: String; var summaryTitle: String; var phase: Phase; init(source: JournalEntry.Source, store: any JournalStore, assistant: (any JournalAssisting)?, modelReady: Bool); func beginIfNeeded() (`SummaryPolicy.shouldSummarize` なら要約開始); func stopSummary(); func save(useTranscriptOnly: Bool) async }` — 保存: 要約済みかつ `useTranscriptOnly == false` なら `body = summaryBody, transcript = transcript, title`、それ以外は `body = transcript, transcript = nil`。fake は Task 7 の `JournalAssisting` に準拠させる。
- `@MainActor @Observable final class AskSession { var answer: String; var evidence: [PackedEntry]; var usedRecentFallback: Bool; var phase: ...; func ask(_ question: String); func stop() }`
- RootTabView: タブ「日誌」「聞く」「チャット」。JournalView: 日付ごとのセクション（新しい順）、検索欄（`store.search`）、各行に見出し／本文冒頭／音声・テキストのアイコン／スワイプ削除、下部に録音ボタン（`SpeechCapture.reason` があれば無効 + 文言）とテキスト欄 + 「記録」。録音停止・「記録」で JournalCaptureView（本文編集、要約の逐次表示と「停止」、見出し編集、「保存」「原文のまま保存」）。AskJournalView: 質問欄、回答の逐次表示、「停止」、根拠一覧（日付・冒頭 60 文字、タップで本文）。モデル未準備なら「聞く」はモデル管理への導線と理由を表示。
- [ ] Tests: `shortTextSkipsSummary`, `longTextWithModelSummarizes`, `stopDuringSummaryKeepsTranscript`（停止後 `save(useTranscriptOnly: true)` で原文が保存される）, `saveWithSummaryStoresBothTexts`, `modelNotReadyStillSaves`, `askShowsEvidenceAndFallbackFlag`。

### Task 10: ゲート結果の反映・Docs・CI
- [ ] `docs/phase2-mlx-eval.md` にユーザー報告の数値・品質を記入し、既定モデルと `GenerateParameters`、プロンプト文言を確定（必要なら `JournalPrompts` と Registry を更新し CI 緑）。
- [ ] `SwiftDataNoteStore.swift` を削除（参照が残っていないことを CI で確認）。
- [ ] `docs/phase0-checklist.md` に Phase 2 節（実機で未検証の一覧: 長時間文字起こし、機内モード AT-02、ダウンロード中断、メモリ警告、回答品質）、`docs/test-plan.md`（AT-02/AT-15/FR-15）、`docs/decisions.md`（ADR-020 MLX は AgentRunner を通さない、ADR-021 日誌は MLX 専用で Claude ツールは noteTool のみ、ADR-022 2 段階検索と日付母集合、ADR-023 ダウンロード方針、ADR-024 既定モデルとゲート結果、ADR-025 VersionedSchema 導入）、`docs/testflight-setup.md` に再配信手順を追記し push。
