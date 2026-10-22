# 第2段階 FM ハーネス Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 端末内モデル（Apple・MLX）のチャット・日誌・会議・検証画面を Foundation Models の `LanguageModelSession` に移し、端末内チャットで 5 種のメモツールを承認付きで使えるようにする。

**Architecture:** AgentRunKit はフォーク（MLX なし）にして Claude 経路だけに残す。端末内は `any FoundationModels.LanguageModel`（`SystemLanguageModel.default` / `MLXLanguageModel`）を、テキスト用の `FoundationModelsTextClient`（AgentRunKit `LLMClient` 準拠）と、チャット用の `OnDeviceTurnRunner`（毎ターン新しいセッション、greedy、ツール付き）の 2 つの入口で使う。メモツールは既存の `NoteTools` → `ToolApprovalGate` → 記録、の上に FM `Tool` の薄い型をかぶせる。

**Tech Stack:** Swift 6 / SwiftUI / iOS 27 Foundation Models / mlx-swift-lm 3.32.3（MLXFoundationModels, MLXHuggingFace）/ AgentRunKit fork 6.1.0-pocket.1 / XcodeGen / GitHub Actions `xcode-27`

**Spec:** `docs/superpowers/specs/2026-10-23-stage2-fm-harness-design.md`

## Global Constraints
- deploymentTarget iOS 27.0、Swift 6 strict concurrency complete、Xcode 27.0（`ci/select-xcode.sh`）。
- AgentRunKit は `https://github.com/beesan82/AgentRunKit.git` exact `6.1.0-pocket.1`（project.yml と `Packages/PocketAgentRuntime/Package.swift` の両方）。
- 新しい pin（スパイク CI で解決済みの値）: mlx-swift-lm `3.32.3`、mlx-swift `0.32.3`、swift-huggingface `0.13.0`、swift-transformers `1.3.5`。すべて exact。
- FM の型は必ず `FoundationModels.Tool` / `FoundationModels.LanguageModel` と修飾する（`MLXLMCommon` と同名）。
- 端末内経路は Claude の API キーを読まない・Claude クライアントを作らない（AT-14）。MLX の読み込みはローカルディレクトリのみ（ADR-023）。
- 端末内チャットの生成は `GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)`。毎ターン新しい `LanguageModelSession`。
- 畳み込みの文言は一字一句（下の Task 1）。
- 書き込みツール（save / edit / delete）は承認必須。ネイティブの読み取りツールは承認なし。救済は必ず承認。
- Windows で Swift は動かない。各タスクの「Run」は GitHub Actions で行う: `git push` → `"C:\Program Files\GitHub CLI\gh.exe" workflow run ios-ci.yml --ref stage2-fm-harness` → 60 秒間隔で `gh run view <id> --json status,conclusion` を確認（`gh run watch` を並行で回さない。二次レート制限で 403 になる）。
- RED（意図した失敗）を確かめるときだけ、このブランチのワークフローでテストステップに一時的に `continue-on-error: true` を付け、ログで失敗を読む。外してから GREEN を確かめる。main へは全タスク GREEN の後にだけ入れる。
- ユーザー向けの文言・ログ・コメントの言語は既存に合わせる（UI 文言は日本語、コードコメントは英語）。

## Review Focus
1. **ダウンロード済みのモデルがある端末で更新した**: 再ダウンロードなしで読み込めること（保存先 `AppSupport/Models/models/<repo id>` を変えない）→ Task 2 のテスト `downloaderDirectoryLayoutUnchanged`。
2. **承認シートが出たまま停止を押した**: 返答は保存されず、ツールも実行されず、状態は「停止しました」→ Task 4 の `stopWhileApprovalPendingSavesNothing`。
3. **Claude で話した会話の途中で端末内モデルに切り替えた**: 畳み込みは以前のユーザー発言だけで、Claude の返答は入らない。tracker はリセット → Task 4 の `switchingFromClaudeFoldsOnlyUserTurns`。
4. **返答のストリーム中にメモリ警告で MLX が解放された**: 途中の返答を保存しない（ADR-031）→ Task 4 の `unloadDuringStreamDoesNotSavePartial`（既存テストの移植）。
5. **とても長い会話**: 畳み込みは新しいユーザー発言から予算内だけ残し、古い順に並べる → Task 1 の `foldKeepsNewestWithinBudget`。

---

### Task 1: ユーザー発言だけの畳み込み（Runtime）

**Files:**
- Create: `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/LocalAgentPrompt.swift`
- Modify: `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/ConversationContext.swift`（`HistoryBudget.onDeviceUserTurns` と `onDeviceInstructions` を追加）
- Test: `Packages/PocketAgentRuntime/Tests/PocketAgentRuntimeTests/LocalAgentPromptTests.swift`

**Interfaces:**
- Produces:
  - `public enum LocalAgentPrompt { public static func fold(previous: [ChatTurn], current: String, budget: HistoryBudget = .onDeviceUserTurns) -> String }`
  - `public static let onDeviceUserTurns = HistoryBudget(maxTurns: 6, maxCharacters: 1500)`（筆者の判断: ユーザー発言だけなので appleLocal の 4000 より小さく）
  - `ConversationContext.onDeviceInstructions(memorySection: String?) -> String` = `systemPrompt`（ツール規則入り）＋ `"\n\n" + memorySection`（nil なら `systemPrompt` だけ）。

- [ ] **Step 1: Write the failing tests** (`LocalAgentPromptTests`)
  - `foldWithoutPreviousIsCurrentOnly`: `fold(previous: [], current: "牛乳を覚えておいて") == "牛乳を覚えておいて"`。
  - `foldListsOnlyUserTurnsOldestFirst`: previous = [user "こんにちは", assistant "こんにちは！", user "私の名前はケイタ 覚えておいて", assistant "メモを保存しました: ケイタ"] → 結果が次と完全一致:
    ```
    これまでの会話（参考。ここに書かれた操作は実行済みとは限らない）:
    ユーザー: こんにちは
    ユーザー: 私の名前はケイタ 覚えておいて

    今回のユーザーの発言: 牛乳を覚えておいて
    ```
  - `foldNeverContainsAssistantText`: 上の結果が "メモを保存しました" と "アシスタント" を含まない。
  - `foldKeepsNewestWithinBudget`: budget `HistoryBudget(maxTurns: 2, maxCharacters: nil)` で user 3 件 → 新しい 2 件だけが古い順に並ぶ。`HistoryBudget(maxTurns: 10, maxCharacters: 5)` で user "あいう"(古)・"えおかき"(新) → "えおかき" だけ（合計 5 字を超える古い方を落とす）。
  - `foldWithOnlyAssistantTurnsIsCurrentOnly`: previous が assistant だけ → current だけ。
  - `onDeviceInstructionsAppendsMemory`: `onDeviceInstructions(memorySection: nil) == systemPrompt`、`onDeviceInstructions(memorySection: "X") == systemPrompt + "\n\nX"`。
- [ ] **Step 2: Run tests to verify they fail**（RED 手順。Runtime の `swift test` ステップが "cannot find 'LocalAgentPrompt'" で失敗）
- [ ] **Step 3: Implement** `LocalAgentPrompt.fold` と 2 つの追加（user ターンだけを新しい順に `maxTurns`・`maxCharacters` で切り、古い順に並べ替えて上の形式で連結。1 件も残らなければ `current` をそのまま返す）
- [ ] **Step 4: Run tests to verify they pass**（Runtime package tests GREEN）
- [ ] **Step 5: Commit** `feat(runtime): LocalAgentPrompt - fold only the user's earlier turns for on-device chat`

---

### Task 2: 依存の差し替えと端末内モデルの土台（日誌・検証画面は FM へ、チャットは見た目そのまま）

このタスクの終わりでアプリはビルド・テストとも GREEN。チャットの `.mlxLocal` はまだテキストのみ（`LocalChat` を新しい text client で動かす）、`.appleLocal` チャットはまだ `AgentRunKitFoundationModels` の `FoundationModelsClient`（この製品はフォークに残っており、Task 4 で外す）。

**Files:**
- Modify: `project.yml`（packages / dependencies）、`Packages/PocketAgentRuntime/Package.swift`、`Packages/PocketAgentRuntime/Package.resolved`
- Create: `App/Package.resolved`（アプリの全 pin。CI が xcodeproj にこれを複写し、解決後に一致を検査）
- Modify: `.github/workflows/ios-ci.yml`（pin の複写元を `App/Package.resolved` に。Runtime の pin は「両方にある identity の revision が一致」を検査。`xcodebuild` 全呼び出しに `-skipMacroValidation -skipPackagePluginValidation`）、`codemagic.yaml`（同じ複写元とフラグ）
- Create: `App/PocketAgent/OnDevice/FoundationModelsTextClient.swift`、`App/PocketAgent/OnDevice/OnDeviceGeneration.swift`
- Modify: `App/PocketAgent/MLX/MLXRuntime.swift`、`App/PocketAgent/MLX/MLXModelStore.swift`（`HubModelDownloader`）、`App/PocketAgent/MLX/DeviceProbes.swift`、`App/PocketAgent/Journal/JournalModelAccess.swift`（Apple を text client に）、`App/PocketAgent/Adapters/SDKLinkCheck.swift`
- Test: `App/PocketAgentTests/OnDeviceGenerationTests.swift`、`App/PocketAgentTests/MLXRuntimeTests.swift`、`App/PocketAgentTests/MLXModelStoreTests.swift`、`App/PocketAgentTests/SDKLinkCheckTests.swift`、`App/PocketAgentTests/JournalModelAccessTests.swift`

**Interfaces:**
- Produces:
  - `struct OnDeviceGeneration: Equatable { var maxTokens: Int?; var temperature: Double?; static func from(_ context: RequestContext?) -> OnDeviceGeneration }`（`extraFields["max_tokens"]` の `.int`、`["temperature"]` の `.double`。他のキーは無視）
  - `struct FoundationModelsTextClient: LLMClient { init(model: any FoundationModels.LanguageModel); providerIdentifier = .foundationModels }` — 呼ぶたびに新しい `LanguageModelSession(model:instructions:)`。`.system` を改行 2 つで連結して instructions、`.user` / `.assistant` の本文を改行 2 つで連結して prompt。`tools` 引数は無視（空でなければ assert しない）。`stream` は `streamResponse` の累積スナップショットの差分を `.content` で流し、最後に `.finished` 相当（AgentRunKit の `StreamDelta` の終端の形は既存の `StreamBridge.contentOnly` が `.content` だけ見るので、`.content` だけ流して終了してよい）。`GenerationOptions(temperature:maximumResponseTokens:)` は `OnDeviceGeneration.from`。
  - `struct LoadedOnDeviceModel: Sendable { let textClient: any LLMClient; let languageModel: (any FoundationModels.LanguageModel)?; let release: @Sendable () async -> Void }`（`languageModel` は Task 4 のチャットで使う。テストの偽物では nil でよい）
  - `protocol ModelLoading: Sendable { func load(_ model: MLXModelInfo, directory: URL) async throws -> LoadedOnDeviceModel }`（`releaseMemory()` は削除。解放は `LoadedOnDeviceModel.release`）
  - `MLXRuntime`: `client: (any LLMClient)?`（= `loaded.textClient`、既存の呼び出し元はそのまま）、新規 `languageModel: (any FoundationModels.LanguageModel)?`。解放時は保持していた `release` を `Task { await release() }` で呼ぶ。
  - `MLXModelLoader.load`: `config.json` の確認は残す。`MLXLanguageModel(configuration: ModelConfiguration(directory: directory), capabilities: [.toolCalling], weightsLocation: { _ in directory }, load: { configuration, progress in try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader(), …) })` を作り `try await model.preload()`。`release` は `await model.evict()`。`load` クロージャの正確な引数形は mlx-swift-lm 3.32.3 の `ContainerLoader` と `loadModelContainer(from: URL, using:)` のソースで確認してから書く。
  - `HubModelDownloader.download`: swift-huggingface 0.13.0 の `HubClient().downloadSnapshot(of: model.id, kind: .model, to: Self.directory(of: model, at: base), revision: model.revision, matching: Self.globs, progressHandler:)`。`directory(of:at:)`・`isDownloaded`・`delete`・バックアップ除外は変えない。
  - `SDKLinkCheck`: 表示する型名を `MLXLanguageModel` と `SystemLanguageModel` に。

- [ ] **Step 1: Write the failing tests**
  - `OnDeviceGenerationTests.readsMaxTokensAndTemperature`: `from(RequestContext(extraFields: ["temperature": .double(0.7), "top_p": .double(0.8), "max_tokens": .int(512), "repetition_penalty": .double(1.1)]))` == `OnDeviceGeneration(maxTokens: 512, temperature: 0.7)`。`from(nil)` == `OnDeviceGeneration(maxTokens: nil, temperature: nil)`。
  - `MLXRuntimeTests`: 既存の FakeLoader を `LoadedOnDeviceModel` を返す形に直し、`droppingLoadedModelCallsRelease`（`unload()` 後に release が 1 回呼ばれる）、`supersededLoadReleasesLateModel`（別モデルの load で前の結果が捨てられたとき release が呼ばれる）を追加。既存の状態遷移テストは期待値そのまま。
  - `MLXModelStoreTests.downloaderDirectoryLayoutUnchanged`: `HubModelDownloader.directory(of: MLXModelRegistry.default, at: URL(fileURLWithPath: "/b"))` の path が `/b/models/mlx-community/Qwen2.5-1.5B-Instruct-4bit/`（既定モデルの id は `MLXModelRegistry` の値を使う）。
  - `SDKLinkCheckTests`: 期待する型名を "MLXLanguageModel" に。
  - `JournalModelAccessTests`: Apple 経路の client の `providerIdentifier == .foundationModels`（既存の期待を維持）。
- [ ] **Step 2: Run to verify they fail**（RED 手順。`OnDeviceGeneration` 未定義など）
- [ ] **Step 3: Implement** 依存の差し替え、上の Interfaces、`DeviceProbes` の `import MLX`（0.32.3 の `Memory.activeMemory`）。`MLXValidationView` は `runtime.client` のまま動く（tok/s が出せなければ `tokenUsage` が nil のときの既存表示に任せる）。
- [ ] **Step 4: Run to verify GREEN**（Core / Runtime / Resolve packages（pin 一致）/ シミュレータ・実機ビルド / Unit tests すべて success）
- [ ] **Step 5: Commit** `feat(app): on-device inference via Foundation Models (MLXLanguageModel, SystemLanguageModel); AgentRunKit fork without MLX`

---

### Task 3: FM 用メモツールとターン実行（App）

**Files:**
- Create: `App/PocketAgent/OnDevice/NoteToolBridge.swift`、`App/PocketAgent/OnDevice/FMNoteTools.swift`、`App/PocketAgent/OnDevice/OnDeviceTurnRunner.swift`
- Test: `App/PocketAgentTests/NoteToolBridgeTests.swift`

**Interfaces:**
- Consumes: Task 2 の `FoundationModels.LanguageModel` の取り方。既存 `NoteTools.make` / `ToolApprovalGate.wrap` / `NoteToolName`。
- Produces:
  - `enum NoteToolBridge { static func invoke(_ name: String, argumentsJSON: String, tools: [any AnyTool<EmptyContext>]) async throws -> String }` — `tools` から名前で探し `execute(arguments: Data(argumentsJSON.utf8), context: EmptyContext())`、結果の `content` を返す（`isError` でも `content` を返す。モデルに理由を読ませる）。見つからなければ `"Unknown tool: <name>"`。`CancellationError` はそのまま投げる。
  - `FMNoteTools.make(_ tools: [any AnyTool<EmptyContext>]) -> [any FoundationModels.Tool]` — 渡された各 AnyTool の名前に対応する FM の型（`SaveNoteFMTool`, `EditNoteFMTool`, `ListNotesFMTool`, `SearchNotesFMTool`, `DeleteNoteFMTool`）を作る。各型は `name` / `description` を inner からコピーし、`@Generable struct Arguments`（save: `text`、edit: `id`,`text`、list: なし、search: `query`、delete: `id`。`@Guide` の説明は NoteTools の JSON Schema の description と同じ文言）を `Codable` の鏡像 struct で JSON にして `NoteToolBridge.invoke` を呼ぶ。`Output` は `String`。
  - `protocol OnDeviceTurnRunner: Sendable { func run(instructions: String, prompt: String, tools: [any AnyTool<EmptyContext>]) -> AsyncThrowingStream<String, Error> }`（返すのは本文の差分チャンク。チャットの `streamingText` に足していく）
  - `struct FoundationModelsTurnRunner: OnDeviceTurnRunner { init(model: any FoundationModels.LanguageModel) }` — 新しい `LanguageModelSession(model:tools: FMNoteTools.make(tools), instructions:)`、`streamResponse(to: prompt, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 512))` の累積スナップショットから差分を流す。消費側の終了でストリームのタスクを cancel する（`StreamBridge.contentOnly` と同じ形）。

- [ ] **Step 1: Write the failing tests** (`NoteToolBridgeTests`, InMemory の `MemoryStore` と `NoteTools.make(store:limit: .appleLocal)` を使う。ゲートは通さない素のツール)
  - `invokeSaveStoresNote`: `invoke("save_note", argumentsJSON: #"{"text":"牛乳"}"#, …)` の後、store に "牛乳" が 1 件。返り値は NoteTools の save 成功の content と同じ。
  - `invokeReturnsErrorContent`: `invoke("edit_note", argumentsJSON: #"{"id":"not-a-uuid","text":"x"}"#, …)` が NoteTools のエラー文（content）を返し、throw しない。
  - `invokeUnknownTool`: `invoke("nope", …) == "Unknown tool: nope"`。
  - `invokeThroughGateDeniedDoesNotSave`: `ToolApprovalGate.wrap(tools, approval: { _ in .deny(nil) })` を渡して save → store は空、返り値は "Tool call denied by user." で始まる。
- [ ] **Step 2: Run to verify they fail**（RED）
- [ ] **Step 3: Implement** 3 ファイル（FM の型のテストは実モデルが要るので書かない。ブリッジでロジックを固める）
- [ ] **Step 4: Run to verify GREEN**（シミュレータ・実機ビルドで `@Generable` と `FoundationModels.Tool` 準拠がコンパイルできることも確認）
- [ ] **Step 5: Commit** `feat(app): Foundation Models note tools over the gated NoteTools; OnDeviceTurnRunner`

---

### Task 4: 端末内チャットを 1 本に（承認付きツール・畳み込み・救済・非対応表示）

**Files:**
- Create: `App/PocketAgent/Chat/OnDeviceModelAccess.swift`（`LocalModelAccess.swift` を置き換え、旧ファイルは削除）
- Modify: `App/PocketAgent/Chat/ChatSession.swift`、`App/PocketAgent/Adapters/LLMClientFactory.swift`、`App/PocketAgent/Views/ChatView.swift`（`ChatSession` の生成箇所）、`App/PocketAgent/PocketAgentApp.swift`（必要なら生成の配線）、`App/PocketAgent/Journal/JournalModelAccess.swift`（Task 2 の Apple text client のまま。`AgentRunKitFoundationModels` の import を消す）、`project.yml`（製品 `AgentRunKitFoundationModels` を外す）
- Delete: `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/LocalChat.swift`、`Packages/PocketAgentRuntime/Tests/PocketAgentRuntimeTests/LocalChatTests.swift`、`ConversationContext.appleLocalPrompt` の 2 つのオーバーロードと `localChatSystemPrompt`、それらの Runtime テスト（`ConversationContextTests` の appleLocalPrompt 系）
- Test: `App/PocketAgentTests/ChatSessionLocalTests.swift`（書き換え）、`App/PocketAgentTests/ChatSessionTests.swift`（`.appleLocal` のテストを ChatSessionLocalTests へ移し、Claude のテストは変えない）、`App/PocketAgentTests/LLMClientFactoryTests.swift`

**Interfaces:**
- Consumes: Task 1 `LocalAgentPrompt.fold`、`ConversationContext.onDeviceInstructions`。Task 3 `OnDeviceTurnRunner`、`FoundationModelsTurnRunner`。Task 2 `MLXRuntime.languageModel`。
- Produces:
  - `@MainActor protocol OnDeviceModelAccess { func reason(for choice: ModelChoice) -> ModelUnavailableReason?; func runner(for choice: ModelChoice) async -> (any OnDeviceTurnRunner)? }`（`choice` は `.appleLocal` / `.mlxLocal` だけで呼ばれる）
  - `struct LiveOnDeviceModelAccess: OnDeviceModelAccess { let store: MLXModelStore; let runtime: MLXRuntime; let availability: any ModelAvailabilityChecking }` — Apple: `reason` は `availability.appleLocalUnavailableReason()`、runner は `FoundationModelsTurnRunner(model: SystemLanguageModel.default)`。MLX: `reason` は `JournalModelAccess.reason(store:runtime:)`、runner は `JournalModelAccess.client(store:runtime:)` と同じ読み込み規則の後 `runtime.languageModel.map(FoundationModelsTurnRunner.init)`。
  - `ChatSession.init(…, onDevice: any OnDeviceModelAccess, …)`（`localModel:` を置き換え）。`ClientResolver` は `@MainActor (ModelChoice) -> Result<any LLMClient, ModelResolutionError>`（`appleLocalTools` 引数を削除）で、`.claude` のときだけ呼ばれる。
  - `ChatSession.isToolSupportLimited`: `current.isLocal && current == lastChoice && tracker.isLimited`。
- 端末内の 1 ターン（`sendOnDevice(_ choice: ModelChoice, message:previousTurns:)`）:
  1. `reason(for:)` が `.modelLoading` 以外の理由なら `fail(with:)`（読み込まない）。
  2. `.mlxLocal` は `status = .loadingModel`、`.appleLocal` は `.running`。`localSendID` の世代管理は今の `sendLocal` と同じ。
  3. memory を読み（失敗は無視）、`instructions = ConversationContext.onDeviceInstructions(memorySection: memorySection(memory:, limit: .appleLocal))`、`prompt = LocalAgentPrompt.fold(previous: previousTurns, current: message)`。
  4. `tools = NoteTools.make(store: notes, limit: .appleLocal)` を `ToolApprovalGate.wrap(_, approval: approvalHandler)` で包み、さらに `RecordingTool` で包む（今の appleLocal と同じ順）。
  5. `runner.run(instructions:prompt:tools:)` のチャンクを `streamingText` に足す。停止・エラー・`.unloadedForMemory` の扱いは今の `sendLocal` と同じ（途中は保存しない）。
  6. 完了したら、今の `finish` の `.completed(text)` と同じ処理（ネイティブ記録あり → native、なし → `ToolCallRescue` → `runRescued`、`record`）を共通関数にして使う。`record` の tracker 更新は `choice.isLocal` のとき。
- `LLMClientFactory.resolver`: `makeAppleLocal` には「チャットは使わない」ことを示すエラーを投げるクロージャを渡す（Core の `ModelBackendResolver` は変えない。日誌は `JournalModelAccess` 経由）。

- [ ] **Step 1: Write the failing tests**（`FakeOnDeviceModel: OnDeviceModelAccess` と `FakeTurnRunner: OnDeviceTurnRunner`。FakeTurnRunner は台本 `[.callTool(name, json), .text(String)]` を順に実行し、`.callTool` は渡された `tools` の AnyTool を `execute` する＝ネイティブ呼び出しの代わり。受け取った `instructions` / `prompt` を記録する）
  - `nativeSaveAsksAndSaves`（`.appleLocal` と `.mlxLocal` の両方でパラメータ化）: 台本 `[.callTool("save_note", {"text":"ケイタ"}), .text("保存しました")]`、承認 → メモ 1 件、返答が保存、`toolcall.native model=<raw> tool=save_note` がログ。
  - `deniedSaveDoesNotSave`: 拒否 → メモ 0 件、返答は保存される。
  - `stopWhileApprovalPendingSavesNothing`: 承認待ちで `stop()` → メモ 0、返答なし、`status == .failed(RunFailureText.stopped)`。
  - `rescuedJSONAsksAndSaves`: 台本 `[.text("```json\n{\"text\": \"牛乳\"}\n```")]` → 承認シート → 承認でメモ 1、`toolcall.rescued`。
  - `twoMissesMarkLimitedForBothLocalModels`: メモ意図の発話（「覚えておいて」を含む）で `.text("保存しました")` を 2 回 → `isToolSupportLimited == true`（両モデル）。Claude に切り替えると false。
  - `secondTurnFoldsOnlyUserTurns`: 2 ターン目に FakeTurnRunner が受け取った `prompt` が `LocalAgentPrompt.fold(previous: <1 ターン目の user と assistant>, current: <2 ターン目>)` と一致し、1 ターン目の返答文を含まない。
  - `switchingFromClaudeFoldsOnlyUserTurns`: Claude で 1 往復（既存 FakeLLMClient）→ `.mlxLocal` で送信 → prompt に Claude の返答文が無い、tracker リセット。
  - `onDeviceNeverReadsKey`（AT-14）: 既存の「キーを読んだら記録する CredentialStore」を使い、端末内 2 モデルで送信してもキーを読まない・resolver を呼ばない。
  - `unloadDuringStreamDoesNotSavePartial` / `stopDoesNotSavePartial` / `notDownloadedFailsWithoutLoading`: 既存 ChatSessionLocalTests の同名テストを新しい偽物に移植（期待値は同じ）。
  - `instructionsCarryToolRuleAndMemory`: メモが 1 件あるとき `instructions == ConversationContext.onDeviceInstructions(memorySection: <そのメモの section>)`。
  - `LLMClientFactoryTests`: `.appleLocal` の resolver が Foundation Models クライアントを返すテストは削除し、`.claude` のテストは残す。
- [ ] **Step 2: Run to verify they fail**（RED）
- [ ] **Step 3: Implement** 上の流れ。`sendWithAgent` は Claude 専用に簡素化（appleLocal の分岐を削除）。削除対象を消し、`project.yml` から `AgentRunKitFoundationModels` を外す。
- [ ] **Step 4: Run to verify GREEN**（全ステップ success。Runtime の AT-05/08/09 テストが変わらず通ること）
- [ ] **Step 5: Commit** `feat(app): one on-device chat path - Foundation Models session per turn, note tools with approval, user-only fold`

---

### Task 5: ドキュメント・実機手順・main へ

**Files:**
- Modify: `docs/decisions.md`（新 ADR-035: フォークと依存、ADR-036: 端末内は FM・毎ターン新セッション・ユーザー発言だけ畳み込み・greedy・救済と非対応表示を両端末内へ、テキスト経路。ADR-009 / 017 / 031 / 032 に「置き換え: ADR-035/036」を追記）、`docs/architecture.md`、`AGENT_REQUIREMENTS.md`（`AgentRunKitMLX` の記述を「AgentRunKit フォーク＋MLXFoundationModels」に）、`docs/phase0-checklist.md`（実機未検証の項目を追加）
- Create: `docs/verification/2026-10-23-stage2-on-device-tools.md`（iPhone 15 MLX と iPhone 18,5 Apple で: 承認→保存、拒否、2 ターン目の保存、承認待ちで停止、メモ非対応表示、日誌の要約、日誌に聞く、会議モードの要点、機内モードでの読み込み、更新前にダウンロード済みのモデルがそのまま使えること。結果記入欄つき。結果が出るまで未検証と明記）

- [ ] **Step 1: 書く**（ADR 番号は main の最新を確認してから。ADR-033/034 は会議モードで使用済み）
- [ ] **Step 2: ブランチの CI GREEN を確認**（docs だけの変更は CI が走らないので、最後のコード変更時の run id を ADR の検証欄に書く）
- [ ] **Step 3: main に入れる**: `git fetch` → `git rebase origin/main`（衝突は解決）→ dispatch で GREEN を再確認 → `git push origin HEAD:main` → main の CI を確認
- [ ] **Step 4: Commit** `docs: ADR-035/036, stage-2 device verification procedure`（Step 3 の前に）
