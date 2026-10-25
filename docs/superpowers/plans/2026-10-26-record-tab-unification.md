# Record Tab Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 日誌と会議を一つの「記録」タブにまとめ、そこから会議録音をすぐ始められるようにする。

**Architecture:** 保存先の `JournalStore` とアプリ所有の `MeetingSession` は維持する。`JournalView` を記録ホームとし、`MeetingView` をその遷移先にする。会議画面は通常表示と初回自動開始を区別する。

**Tech Stack:** Swift 6、SwiftUI、XCTest、XcodeGen、iOS 27（`project.yml` の現行設定）。

**Spec:** `docs/superpowers/specs/2026-10-26-record-tab-unification-design.md`

## Global Constraints

- `MeetingSession` はアプリで一つとし、画面遷移やチャットへの切替で録音を止めない。
- 日誌・会議の既存データ形式、端末内モデルの扱い、二言語の翻訳・要点更新は維持する。
- 「会議を開始」は前回の言語設定で録音を試みる。権限やデータが足りなければ既存の準備導線を示す。
- 関係ない未追跡ファイルを変更・ステージしない。

## Review Focus

- 会議開始を押して画面が再表示されても、同じ会議を二重に開始しない。
- 会議中にチャットへ移って戻っても、録音状態が残り、会議画面へ戻れる。
- 保存成功後に記録一覧へ戻ると、新しい会議が現れる。
- 保存失敗後に記録ホームへ戻っても、再試行できる会議へ戻れる。
- 録音の許可・言語データが不足する初回利用時、理由と準備操作が表示される。

---

### Task 1: 会議画面の一回だけの自動開始

**Files:**
- Modify: `App/PocketAgent/Views/MeetingView.swift`
- Test: `App/PocketAgentTests/MeetingSessionTests.swift`（既存の開始・再開・保存テスト）

**Interfaces:**
- Consumes: `MeetingSession.start()` と `state`。
- Produces: `MeetingView` の `autoStart: Bool = false`。`true` の初回表示時のみ既存の `startMeeting()` を呼ぶ。

- [ ] **Step 1: 既存の `MeetingSession` テストを確認する。** 開始の重複防止、中断・再開、保存失敗・再試行のカバレッジを把握する。
- [ ] **Step 2: 自動開始を実装する。** `MeetingView` に起動時一回だけのガードを置く。録音中・準備中・保存中なら再度開始せず、`autoStart == false` なら従来の待機画面を出す。
- [ ] **Step 3: 初回利用の導線を確認する。** 権限または音声データ不足時は既存の `speechAvailability` と準備ボタンが見えるようにする。会議画面の再表示で `startMeeting()` が再実行されないことを確認する。
- [ ] **Step 4: このタスクの変更をコミットする。**

### Task 2: 記録ホームとタブ統合

**Files:**
- Modify: `App/PocketAgent/Views/RootTabView.swift`
- Modify: `App/PocketAgent/Views/JournalView.swift`
- Test: 既存の `App/PocketAgentTests/MeetingSessionTests.swift` と日誌関連テスト

**Interfaces:**
- Consumes: Task 1 の `MeetingView(autoStart:)`、`MeetingSession.state`、既存の `JournalView`。
- Produces: `JournalView` に `meeting: MeetingSession`、会議への「開始」「準備・言語」「戻る」の導線。

- [ ] **Step 1: 変更前のテストと構成を確認する。** `RootTabView` に三つのタブがあり、会議と日誌が同じストアを参照することを確認する。
- [ ] **Step 2: タブと導線を実装する。** `RootTabView` を「記録」「チャット」にし、`JournalView` へ `meeting` と会議画面を開く依存を渡す。記録ホームに「会議を開始」と「会議の準備・言語」を置き、進行中または保存失敗時は会議へ戻る導線を表示する。
- [ ] **Step 3: 一覧更新を実装する。** 会議を保存して記録ホームに戻った際に `reloadToken` を更新し、一覧・検索結果を再取得する。
- [ ] **Step 4: 差分を確認する。** `git diff --check` が成功し、既存の記録入力・検索・削除・設定導線が残っていることを読む。
- [ ] **Step 5: このタスクの変更をコミットする。**

### Task 3: 統合検証と説明の更新

**Files:**
- Modify: `docs/test-plan.md` または `docs/verification/` の対象手順
- Modify: `README.md`（実態と異なる古い画面説明があれば更新）
- Test: macOS CI のアプリビルドとテスト

**Interfaces:**
- Consumes: Task 1・2 の完成した画面導線。
- Produces: タブ統合の確認手順と検証結果。

- [ ] **Step 1: 古い画面名と導線を検索する。** `rg -n '日誌タブ|会議タブ|Tab\("日誌"|Tab\("会議"' App docs README.md`。
- [ ] **Step 2: 現行の手順を直す。** 二つのタブ、会議開始、録音中の復帰、保存後の一覧更新、保存失敗の再試行を記載する。
- [ ] **Step 3: 検証する。** `git diff --check` と利用可能な macOS CI でビルド・テストを実行し、成功・失敗と実機未確認項目を記録する。
- [ ] **Step 4: 計画・設計文書と検証記録を含めてコミットする。**
