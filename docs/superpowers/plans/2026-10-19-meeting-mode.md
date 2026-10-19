# 会議モード（リアルタイム文字起こし + 随時要点）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 対面会議中に iPhone が端末内で文字起こしを流し続け（ロック中も）、前面にいる間は端末内 LLM が要点を差分更新し、終了時に全文と要点を日誌 1 件として保存する「会議」タブを作る。

**Architecture:** セグメント型・整形・更新条件・タイトルは Core の純粋関数。要点の差分更新プロンプトは Runtime の `JournalAssistant` に 1 メソッド追加。App では `SpeechCapture` に確定セグメントのイベントストリームを足し、`MeetingSession`（@Observable、アプリで 1 つ）がセグメント・要点・保存を司り、`MeetingView` が表示する。前面判定は `ContentView` の `scenePhase` から流し込む。

**Tech Stack:** Swift 6 / SwiftUI / Speech (SpeechAnalyzer, iOS 26) / AVFoundation / AgentRunKit 6.1.0 (`LLMClient.stream`) / swift-testing / xcodegen（project.yml）

**Spec:** `docs/superpowers/specs/2026-10-19-meeting-mode-design.md`

## Global Constraints
- Core は Foundation のみ。Runtime は AgentRunKit + Core のみ。Speech / MLX / UIKit は App だけ。
- 会議の音声・文字・要点は端末外へ送らない（Claude へのリクエストに乗せない）。
- 全文の保存は常に可能。要点が無い／失敗しても `finish()` は全文を保存する。
- 画面の失敗文言は固定文のみ（`error` 本体は出さない）。文言は日本語。
- 要点の自動更新: 未反映 **300 文字以上** かつ 前回更新開始から **60 秒以上**（初回は文字数のみ）かつ 前面 かつ モデル準備済み かつ 更新中でない。手動は未反映 1 文字以上 かつ モデル準備済み かつ 更新中でない。`max_tokens` 512、その他は `JournalAssistant.context` と同じ。
- 要点の見出しは `## 決まったこと` / `## 宿題` / `## 論点・未決` の 3 つ固定。各見出し最大 7 項目。
- 全文の行形式 `[mm:ss] 本文`（1 時間以上は `h:mm:ss`）。日誌タイトル `会議 M/d HH:mm`（例 `会議 10/19 14:00`）。
- 更新停止時は部分出力を捨て前回の要点を保持。失敗時も同様で未反映は減らさない。
- バックグラウンド録音: `UIBackgroundModes` に `audio`。
- 開発 PC では Swift がコンパイルできない。検証は GitHub Actions（`.github/workflows/ios-ci.yml`）。**RED は一時ブランチ（`continue-on-error: true` を test ステップに付ける）で `gh workflow run ios-ci.yml --ref <branch>` → `gh run view --log` で読む。main には GREEN だけ push**（メモリ `red-runs-off-main`）。push 後は `gh run watch` で確認。
- この checkout は別セッションと共有している可能性がある。実装は専用 worktree／ブランチで行い、main への反映は各タスクの GREEN 確認後に `git merge --ff-only` または通常 merge で行う。

## Review Focus
1. ロック中に届いた確定文（前面でない）→ 要点は走らず未反映が増え、前面復帰で 1 回だけ追いつく（Task 4 `becomingForegroundCatchesUp`）。
2. 更新中に届いた確定文 → その更新には含まれず、次回の未反映に残る（Task 4 `segmentsArrivingDuringUpdateStayPending`）。
3. 文字起こし側の失敗（アセット消失・ストリーム失敗）→ `paused` になりセグメントは残り、終了で保存できる（Task 4 `sourceFailureBecomesPausedAndKeepsSegments`）。
4. セグメント 0 件で終了 → 保存せず文言（Task 4 `finishWithNoSegmentsDoesNotSave`）。
5. 1 時間を超える会議の時刻表示 → `1:00:05` の形（Task 1 `timestampPastOneHour`）。

---

### Task 1: Core — セグメント・整形・更新条件・タイトル
**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/MeetingTranscript.swift`
- Test: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/MeetingTranscriptTests.swift`

**Interfaces (Produces):**
```swift
public struct TranscriptSegment: Sendable, Equatable, Identifiable {
    public let id: UUID; public let offset: TimeInterval; public let text: String
    public init(id: UUID = UUID(), offset: TimeInterval, text: String)
}
public enum MeetingTranscriptFormatter {
    public static func timestamp(_ offset: TimeInterval) -> String   // "mm:ss" / "h:mm:ss"
    public static func text(_ segments: [TranscriptSegment]) -> String  // "[mm:ss] 本文" を "\n" で連結
}
public enum MeetingNotesPolicy {
    public static let minPendingCharacters = 300
    public static let minInterval: TimeInterval = 60
    public static func shouldAutoUpdate(pendingCharacters: Int, secondsSinceLastUpdate: TimeInterval?, isForeground: Bool, modelReady: Bool, isUpdating: Bool) -> Bool
    public static func shouldManualUpdate(pendingCharacters: Int, modelReady: Bool, isUpdating: Bool) -> Bool
}
public enum MeetingTitle {
    public static func make(start: Date, calendar: Calendar = .current) -> String  // "会議 M/d HH:mm"
}
```

- [ ] **Step 1: Write the failing tests** — `MeetingTranscriptTests`:
  - `timestampUnderOneHour`: `timestamp(65) == "01:05"`, `timestamp(0) == "00:00"`, `timestamp(599.9) == "09:59"`（切り捨て）。
  - `timestampPastOneHour`: `timestamp(3605) == "1:00:05"`。
  - `textJoinsLinesWithTimestamps`: 2 セグメント `(offset: 3, "おはよう")`, `(offset: 70, "始めます")` → `"[00:03] おはよう\n[01:10] 始めます"`。空配列 → `""`。
  - `autoUpdateNeedsAllConditions`: `(300, nil, true, true, false)` → true。文字 299 → false。`secondsSinceLastUpdate: 59` → false、`60` → true。`isForeground: false` / `modelReady: false` / `isUpdating: true` のそれぞれで false。
  - `manualUpdateNeedsOnlyPendingAndModel`: `(1, true, false)` → true、`(0, true, false)` → false、`(1, false, false)` → false、`(1, true, true)` → false。
  - `titleUsesMonthDayHourMinute`: 2026-10-19 14:05 JST（`Calendar(identifier: .gregorian)` + `TimeZone(identifier: "Asia/Tokyo")`）→ `"会議 10/19 14:05"`。
- [ ] **Step 2: RED を一時ブランチで確認**（Run: `gh workflow run ios-ci.yml --ref red/meeting-1` → Core テストが「MeetingTranscript が無い」で失敗）
- [ ] **Step 3: Implement** `MeetingTranscript.swift`（timestamp は `Int(offset)` を時分秒に分解。`MeetingTitle` は `DateFormatter`（`en_US_POSIX`、`calendar`/`timeZone` を引数の calendar から、`dateFormat: "M/d HH:mm"`）に `"会議 "` を前置）。
- [ ] **Step 4: GREEN を確認**（Run: CI、Core テスト全 PASS）
- [ ] **Step 5: Commit** `feat(core): meeting transcript segments, formatter, notes policy, title`

### Task 2: Runtime — 要点の差分更新
**Files:**
- Modify: `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/JournalAssistant.swift`（protocol + 実装）, `JournalPrompts.swift`
- Modify: `App/PocketAgentTests/JournalCaptureSessionTests.swift:7-33`（`FakeJournalAssistant` に新メソッドを追加しないとビルドが落ちる）
- Test: `Packages/PocketAgentRuntime/Tests/PocketAgentRuntimeTests/JournalAssistantTests.swift`

**Interfaces:**
- Consumes: `ScriptedTextClient(generate:stream:)`（Runtime tests）、`JournalAssistant.contentOnly` / `context(maxTokens:)`。
- Produces:
```swift
// JournalAssisting に追加
func updateMeetingNotes(previous: String, newText: String) -> AsyncThrowingStream<String, Error>
// JournalPrompts に追加
public static let meetingNotesSystem: String
public static func meetingNotesUser(previous: String, newText: String) -> String
```
`meetingNotesSystem` の要旨（文言は実装者が整える）: 会議の書記。前回の要点と新しい発言から要点を更新し **全文** を出力。見出しは `## 決まったこと` `## 宿題` `## 論点・未決` の 3 つ固定・この順。各見出し最大 7 項目の箇条書き（`- `）。宿題は `- 内容（担当: 〇〇、期限: 〇〇）`（不明なら省く）。固有名詞・数字・日時は落とさない。発言に無いことは書かない。前置き・説明は書かない。
`meetingNotesUser`: `previous` が空なら「これまでの要点: （まだありません）」、あれば本文を載せ、続けて「新しい発言:\n\(newText)」、最後に「要点を更新して全文を出力してください。」。

- [ ] **Step 1: Write the failing test** — `JournalAssistantTests.updateMeetingNotesSendsPreviousAndNewAndContentOnly`: `ScriptedTextClient(generate: [], stream: [.deltas([.content("## 決まったこと\n- A"), .content("\n## 宿題\n- B")])])` → `assistant.updateMeetingNotes(previous: "## 決まったこと\n- 旧", newText: "新しい発言です")` を全部読んで `"## 決まったこと\n- A\n## 宿題\n- B"`。記録された `stream` 呼び出しの messages: system が `JournalPrompts.meetingNotesSystem`、user 本文に `"- 旧"` と `"新しい発言です"` の両方を含む。`extraFields["max_tokens"] == .int(512)`。
  同じファイルに `updateMeetingNotesWithEmptyPreviousSaysNone`: `previous: ""` → user 本文に `"まだありません"` を含む。
- [ ] **Step 2: RED を一時ブランチで確認**（Runtime テストがコンパイルエラーで失敗）
- [ ] **Step 3: Implement** protocol 追加、`JournalPrompts` 追加、`JournalAssistant.updateMeetingNotes`（`summarize` と同じ形: messages → `client.stream` → `contentOnly`、`context(maxTokens: 512)`）。`FakeJournalAssistant` には `var notesChunks: [String] = []`, `var notesFail = false`, `var notesHang = false` と、呼び出し記録 `let notesCalls: NotesCallLog`（`final class NotesCallLog: @unchecked Sendable { private let lock = NSLock(); private(set) var calls: [(previous: String, newText: String)] }`）を追加。`notesFail` ならチャンクの後に `finish(throwing:)`。
- [ ] **Step 4: GREEN を確認**（Runtime + App テスト PASS）
- [ ] **Step 5: Commit** `feat(runtime): incremental meeting notes via JournalAssistant`

### Task 3: App — 文字起こしのイベントストリームとバックグラウンド録音
**Files:**
- Create: `App/PocketAgent/Speech/TranscriptSource.swift`
- Modify: `App/PocketAgent/Speech/SpeechCapture.swift`（`consume`, `start`, `stop`, `cancelPipeline`）, `project.yml`（app target settings に `INFOPLIST_KEY_UIBackgroundModes: audio` を追加。xcodegen がこのキーを Info.plist に出せない場合は target に `info: { path: App/PocketAgent/Info.plist, properties: { UIBackgroundModes: [audio] } }` を使い、既存の `INFOPLIST_KEY_*` は維持）
- Test: なし（ビルドのみ。実機未検証として記録）

**Interfaces (Produces):**
```swift
enum TranscriptEvent: Sendable, Equatable {
    case volatile(String)
    case final(TranscriptSegment)
    case failed(String)   // 固定文言（SpeechCapture.transcriptionFailedText）
}
@MainActor protocol TranscriptSource: AnyObject {
    var reason: SpeechUnavailableReason? { get }
    func refreshAvailability() async
    func requestPermissions() async
    func installAssets() async throws
    /// Returns the event stream of this capture; it ends when the capture stops or fails.
    func start() async throws -> AsyncStream<TranscriptEvent>
    func stop() async
}
extension SpeechCapture: TranscriptSource {}
```

- [ ] **Step 1: Implement** `TranscriptSource.swift`（上記）。
- [ ] **Step 2: Implement in `SpeechCapture`**: `start()` の戻り値を `AsyncStream<TranscriptEvent>` にする（`AsyncStream.makeStream` を `state = .preparing` 直後に作り、`continuation` を `@ObservationIgnored private var events: AsyncStream<TranscriptEvent>.Continuation?` に保持。失敗で throw する前に `finish()`）。`consume` で確定結果ごとに `TranscriptSegment(offset:text:)` を yield（`offset` は `result.range.start.seconds` が有限ならそれ、そうでなければ受信時刻 − `start()` が記録した開始時刻）。仮文は `.volatile(text)`。`handleResultsFailure` で `.failed(Self.transcriptionFailedText)` を yield してから `finish()`。`stop()` / `cancelPipeline()` の最後で `finish()`。既存の `finalText` / `volatileText` はそのまま残す（`JournalView` は無改変で動く。`start()` の戻り値は `JournalView` 側で `_ =` で捨てる）。
- [ ] **Step 3: `project.yml` にバックグラウンド audio を追加**。
- [ ] **Step 4: CI で build（simulator・device 両方）と既存テスト GREEN を確認**。生成された Info.plist に `UIBackgroundModes` が入っていることを CI ログの `xcodegen` 出力か `plutil` で確認するステップを一時的に足してよい（main には入れない）。
- [ ] **Step 5: Commit** `feat(app): transcript event stream and background audio mode`

### Task 4: App — MeetingSession
**Files:**
- Create: `App/PocketAgent/Meeting/MeetingSession.swift`
- Test: `App/PocketAgentTests/MeetingSessionTests.swift`（`FakeTranscriptSource` もここ）

**Interfaces:**
- Consumes: Task 1 の Core 型、Task 2 の `JournalAssisting.updateMeetingNotes`、Task 3 の `TranscriptSource` / `TranscriptEvent`、`JournalStore.add`。
- Produces:
```swift
@MainActor @Observable final class MeetingSession {
    enum State: Equatable { case idle, preparing, recording, paused(String), finishing, saved, failed(String) }
    enum NotesPhase: Equatable { case idle, updating, failed(String) }
    static let startFailedText = "会議を開始できませんでした。もう一度お試しください。"
    static let pausedText = "録音が中断されました。再開してください。"
    static let notesFailedText = "要点を更新できませんでした（前回の要点を表示中）。"
    static let nothingRecognizedText = "音声を認識できませんでした。"
    static let saveFailedText = "保存できませんでした。もう一度お試しください。"

    private(set) var state: State
    private(set) var segments: [TranscriptSegment]
    private(set) var volatileText: String
    private(set) var notes: String
    private(set) var draftNotes: String      // 更新中の途中出力（表示専用）
    private(set) var notesPhase: NotesPhase
    private(set) var startedAt: Date?
    private(set) var isForeground: Bool   // 初期値 true
    var pendingCharacters: Int            // segments[reflectedCount...] の text.count 合計
    var modelReady: Bool                  // assistant != nil
    @ObservationIgnored var assistant: (any JournalAssisting)?   // set すると beginAutoUpdateIfNeeded()

    init(source: any TranscriptSource, store: any JournalStore, assistant: (any JournalAssisting)?, now: @escaping () -> Date = Date.init)
    func start() async          // idle/failed/saved → preparing → recording（source.start を消費する Task を持つ）
    func resume() async         // paused → start と同じ（segments は保持）
    func setForeground(_ value: Bool)   // true になったら beginAutoUpdateIfNeeded()
    func updateNotesNow()       // shouldManualUpdate なら更新
    func stopNotesUpdate()      // 更新 Task をキャンセル、notes は前回のまま、reflectedCount は戻す
    func finish() async         // recording/paused → finishing → 最後の更新（条件付き）→ 保存 → saved / failed
    func retrySave() async      // failed(saveFailedText) から保存だけやり直す
    func reset()                // saved/failed → idle（segments 等を空に）
}
```
動き（実装者が守ること）:
- イベント消費: `.final` → `segments.append`、`volatileText = ""`、`beginAutoUpdateIfNeeded()`。`.volatile` → `volatileText`。`.failed(text)` → `state = .paused(text)`（segments 保持）。ストリーム終了で `.recording` のままなら `.paused(pausedText)`。
- `beginAutoUpdateIfNeeded()`: `MeetingNotesPolicy.shouldAutoUpdate(pendingCharacters:, secondsSinceLastUpdate: lastUpdateStartedAt.map { now().timeIntervalSince($0) }, isForeground:, modelReady:, isUpdating: notesPhase == .updating)` が true なら `runUpdate()`。
- `runUpdate()`: `let upTo = segments.count`、`newText = segments[reflectedCount..<upTo].map(\.text).joined(separator: "\n")`、`lastUpdateStartedAt = now()`、`notesPhase = .updating`、`assistant.updateMeetingNotes(previous: notes, newText:)` を Task で読み、**完了時に** `notes = 全文.trimmed`（空なら失敗扱い）、`reflectedCount = upTo`、`notesPhase = .idle`、続けて `beginAutoUpdateIfNeeded()`。途中チャンクは `draftNotes`（表示用、`private(set) var draftNotes: String`）に積み、完了で `notes` に昇格。エラー → `notesPhase = .failed(notesFailedText)`、`notes` と `reflectedCount` は不変。`generation` カウンタで古い Task の結果を捨てる（`JournalCaptureSession` と同じ流儀）。
- `finish()`: `await source.stop()`；`pendingCharacters > 0 && modelReady && isForeground` なら `runUpdate()` して `await` で待つ（`stopNotesUpdate()` で抜けられる）；`segments.isEmpty` → `state = .failed(nothingRecognizedText)` で保存しない；保存は `notes` 非空なら `NewJournalEntry(source: .voice, origin: .journal, body: notes, transcript: MeetingTranscriptFormatter.text(segments), title: MeetingTitle.make(start: startedAt ?? now()))`、空なら `body = 全文, transcript: nil, title` 同じ。成功 `.saved`、失敗 `.failed(saveFailedText)`。
- 中断通知（`AVAudioSession.interruptionNotification`）の購読は `MeetingSession` ではなく `SpeechCapture` 側で `.failed(pausedText)` 相当のイベントに変換する（Task 5 で追加。ここでは `.failed` → `paused` の経路だけ作る）。

- [ ] **Step 1: Write the failing tests** — `MeetingSessionTests`（`@MainActor`、`InMemoryJournalStore`、`FakeJournalAssistant`、可変クロック `final class Clock { var now = Date(timeIntervalSince1970: 1_000) }`）。`FakeTranscriptSource`: `var reason: SpeechUnavailableReason? = nil`、`var failStart = false`、`private(set) var startCount = 0, stopCount = 0`、`var continuation: AsyncStream<TranscriptEvent>.Continuation?`、`start()` は stream を作って continuation を保持して返す、`stop()` は `continuation?.finish()`。テストは `continuation?.yield(.final(...))` の後 `await Task.yield()` を数回（または `Task.sleep(for: .milliseconds(20))`）して観測する。長文セグメント用に `let long = String(repeating: "あ", count: 300)`。
  - `finalSegmentsAppendAndCountPending`: start → yield `.final(offset: 1, "あ")`, `.volatile("い")` → `segments.count == 1`, `volatileText == "い"`, `pendingCharacters == 1`。
  - `autoUpdateWaitsForThresholdAndForeground`: assistant あり。299 文字 → `notesPhase == .idle`、`notesCalls.calls.isEmpty`。さらに 1 文字 → `.updating` → 完了で `notes == "## 決まったこと\n- A"`、`pendingCharacters == 0`。`setForeground(false)` 後に 300 文字 → 呼ばれない。
  - `becomingForegroundCatchesUp`: 前面でない間に 300 文字 → 未呼び出し → `setForeground(true)` → 1 回呼ばれ `newText` にその 300 文字。
  - `secondUpdateWaitsSixtySeconds`: 1 回目完了直後に 300 文字 → 呼ばれない。`clock.now += 60` して更に 1 文字 → 呼ばれる。
  - `manualUpdateIgnoresThreshold`: 5 文字 → `updateNotesNow()` → 呼ばれる。0 文字では呼ばれない。
  - `segmentsArrivingDuringUpdateStayPending`: `notesHang = true` で更新開始 → その間に 10 文字追加 → `pendingCharacters == 10`（反映待ちは更新開始時点の分を除く）。`stopNotesUpdate()` → `notesPhase == .idle`、`notes == ""`、`pendingCharacters == 310`。
  - `failedUpdateKeepsPreviousNotes`: 1 回目成功 `notes == "X"`、2 回目 `notesFail = true` → `notesPhase == .failed(notesFailedText)`、`notes == "X"`、`pendingCharacters` は 2 回目の分のまま。
  - `finishSavesNotesAndTimestampedTranscript`: `.final(offset: 3, "おはよう")`、`.final(offset: 70, long)` → 自動更新で `notes = "## 決まったこと\n- A"` → `finish()` → `state == .saved`、store の 1 件: `source == .voice`, `body == "## 決まったこと\n- A"`, `transcript == "[00:03] おはよう\n[01:10] \(long)"`, `title == "会議 ..."`（`MeetingTitle.make(start: clock.now)` と等しい）。
  - `finishWithoutModelSavesTranscriptOnly`: assistant nil → `body == 全文`, `transcript == nil`。
  - `finishWithNoSegmentsDoesNotSave`: start → finish → `state == .failed(nothingRecognizedText)`、store 0 件。
  - `sourceFailureBecomesPausedAndKeepsSegments`: 1 セグメント → yield `.failed("x")` → `state == .paused("x")`、`segments.count == 1` → `resume()` → `startCount == 2`、`.recording` → `finish()` で保存される。
  - `startFailureShowsFixedText`: `failStart = true` → `state == .failed(MeetingSession.startFailedText)`。
- [ ] **Step 2: RED を一時ブランチで確認**（App テストがコンパイルエラー）
- [ ] **Step 3: Implement** `MeetingSession.swift`。
- [ ] **Step 4: GREEN を確認**（App テスト全 PASS）
- [ ] **Step 5: Commit** `feat(app): MeetingSession — segments, incremental notes, save`

### Task 5: App — 会議タブ、配線、中断処理、Docs
**Files:**
- Create: `App/PocketAgent/Views/MeetingView.swift`
- Modify: `App/PocketAgent/Views/RootTabView.swift`（タブ「会議」を「聞く」と「チャット」の間に追加、`systemImage: "waveform"`）, `App/PocketAgent/Views/ContentView.swift`（`@Environment(\.scenePhase)` → `meeting.setForeground(phase == .active)`）, `App/PocketAgent/PocketAgentApp.swift`（`@State private var meeting: MeetingSession` を `SpeechCapture()` + journal で 1 つ生成。journal が nil のときは生成しない）, `App/PocketAgent/Speech/SpeechCapture.swift`（`AVAudioSession.interruptionNotification` を購読し、`.began` でパイプラインをキャンセルして `.failed(MeetingSession.pausedText)` ではなく **`SpeechCapture.interruptedText = "録音が中断されました。再開してください。"`** を yield して finish。`.ended` の自動再開は初版ではしない）
- Modify docs: `docs/phase0-checklist.md`（Phase 2 節に「会議モード 実機未検証: ロック中の継続・電話割り込み・1 時間連続・要点品質・録音中のモデル読み込み」）, `docs/test-plan.md`（会議モードの手動確認項目）, `docs/decisions.md`（ADR-026 会議の要点は差分更新・前面のみ、ADR-027 バックグラウンド audio を使う）, `docs/architecture.md`（会議タブと MeetingSession の 1 行）
- Test: なし（画面はビルドのみ）。`MeetingSessionTests` が中断文言を使うなら `MeetingSession.pausedText` を `SpeechCapture.interruptedText` と同じ値にする。

**Interfaces:** Consumes Task 4 の `MeetingSession`、既存 `JournalModelStatusView`、`JournalModelAccess.client(store:runtime:)`、`SpeechCapture` の `reason` / `requestPermissions` / `installAssets`。

画面（spec「画面」節のとおり）:
- `state == .idle / .failed / .saved`: 「会議を開始」大ボタン（`speech.reason != nil` なら無効 + 理由文言 + 既存導線）。`.saved` なら「保存しました」。`.failed(text)` なら text と、`saveFailedText` のときだけ「もう一度保存」。`JournalModelStatusView` を下に表示。
- 開始時: `await meeting.start()` の前に `JournalModelAccess.client(store:runtime:)` を試み、得られたら `meeting.assistant = JournalAssistant(client:)`（モデル未ダウンロードなら assistant なしで開始）。
- `.preparing / .recording / .paused`: 上段 経過時間（`TimelineView(.periodic(from:by: 1))` で `startedAt` から）+ 「終了」。`.paused(text)` なら text + 「再開」。要点カード: `notesPhase == .updating` なら `draftNotes` を薄く + ProgressView + 「停止」、それ以外は `notes`（空なら「要点はまだありません」）、右上「更新」（`shouldManualUpdate` でない時は無効）と「未反映 \(pendingCharacters) 文字」。`notesPhase == .failed(text)` は text を赤の footnote。モデル未準備なら「要点はモデルを読み込むと付きます」+ `JournalModelStatusView`。下段 `ScrollViewReader` + `LazyVStack` のセグメント一覧（`MeetingTranscriptFormatter.timestamp` を secondary の monospacedDigit、本文）、末尾に `volatileText` を secondary。新セグメントで末尾へ `scrollTo`（ユーザーが上にいる間は追従しない: `onScrollGeometryChange` で末尾付近かを持つ）。
- `.finishing`: 「保存しています…」+ 更新中なら「停止」。
- `.saved` 表示後に「新しい会議」で `reset()`。

- [ ] **Step 1: Implement** `MeetingView`、`RootTabView`、`ContentView`、`PocketAgentApp` の配線。
- [ ] **Step 2: Implement** `SpeechCapture` の中断購読（`NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification…)` を `start()` で登録し `stop()`/cancel で解除）。
- [ ] **Step 3: CI で build + 全テスト GREEN を確認**（`gh run watch`）。
- [ ] **Step 4: Docs を更新**（上記 4 ファイル）。
- [ ] **Step 5: Commit** `feat(app): 会議 tab — live transcript, incremental notes, save to journal` → main へ merge → push → `gh run watch`。
- [ ] **Step 6: ユーザーに TestFlight（Codemagic「iOS TestFlight」）の起動を依頼**し、実機確認項目（ロック中継続・割り込み・要点品質・閾値・メモリ）を伝える。結果は `docs/phase2-mlx-eval.md` に追記。
