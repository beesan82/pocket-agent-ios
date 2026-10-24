# 二言語会議（段階 B）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 会議タブで「二言語（日本語・英語）」を ON にすると、日英 2 系統の認識と `LanguageArbiter` で発言ごとに言語を決め、相手の言語へ端末内翻訳して 2 列（左: 日本語、右: English）で表示し、日誌に原文と訳文を保存する。

**Architecture:** Core の `TranscriptSegment` に `language` と `translation` を足し、整形を拡張。`MeetingSession` が二言語のとき `.candidate` を `LanguageArbiter` に通し（0.5 秒ごとの `tick()` で期限切れの組を判定）、採用した候補をセグメントにし、`Translating` の直列キューで訳す。`MeetingView` はトグル・前提条件・2 列表示。

**Spec:** `docs/superpowers/specs/2026-10-23-bilingual-meeting-design.md`（段階 B）。段階 A の実機ゲートは**未計測のまま**ユーザーの指示（2026-10-24「会議タブで二言語が使えるようにしたい」）で着手する。閾値は暫定。

## Global Constraints
- 二言語 OFF（既定）では従来と同じ動き（`SpeechCapture()` 単一ロケール、翻訳なし）。
- 音声・原文・訳文は端末外へ出さない。翻訳の失敗・未導入で文字起こし・要点・保存を止めない。
- 要点の入力は日本語側（ja は原文、en は訳文、訳文が無ければ原文）。要点プロンプトは変えない。
- 終了時は翻訳キューが空になるのを最長 10 秒待ってから保存。間に合わない訳は付けずに保存。
- 失敗した翻訳は前面復帰時と「更新」時に再試行。1 セグメントあたり最大 3 回（初回 + 再試行 2 回）。
- 全文の形: `[mm:ss] 本文`（英語の原文は `[mm:ss] (EN) 本文`）、訳文があれば次の行に `    → 訳文`。
- 二言語の開始条件: 英語の音声データが必要（無ければ開始ボタン無効 + 理由 + 「音声データを入手」）。翻訳データが無ければ開始は可、訳なし + 案内。
- RED は一時ブランチ、main には GREEN のみ。

## Review Focus
1. 二言語で `.final` が来ない（候補のみ）→ 判定後だけセグメント化、二重に出ない（`bilingualCandidatesBecomeSegmentsWithLanguage`）。
2. 終了時に保留中の候補 → `drain` してから保存（`finishDrainsHeldCandidates`）。
3. 翻訳が遅い／失敗 → 原文は残り、保存は 10 秒以内に進む（`translationFailureKeepsOriginalAndRetriesOnForeground`）。
4. 「再開」で認識器の時計がリセット → 判定器も作り直し、時刻は会議開始基準（`resumeStartsAFreshArbiter`）。
5. 二言語 OFF で翻訳が呼ばれない（`bilingualOffNeverTranslates`）。

### Task 1: Core — セグメントの言語と訳文、整形
- Modify `MeetingTranscript.swift`: `TranscriptSegment` に `language: String = "ja"`, `translation: String? = nil`（init の末尾に既定値付きで追加）、`func withTranslation(_:) -> TranscriptSegment`。`MeetingTranscriptFormatter.text` を上記の形に。`TranscriptSegment.japaneseSide: String`（ja → text、en → translation ?? text）。
- Tests: `textIncludesLanguageMarkAndTranslation`、`japaneseSidePrefersTranslationForEnglish`。

### Task 2: App — 二言語の MeetingSession
- `TranscriptSource` に `var elapsed: TimeInterval { get }`（`SpeechCapture` は既存、偽物は設定可能）。`TranscriptEvent` に `laneVolatile(language: String, text: String)`（二言語の `SpeechCapture` が仮文字で出す）。
- `MeetingSession(source:bilingualSource:translator:store:assistant:now:)`。`var bilingual: Bool`（開いていない間だけ変更可）。`var source: any TranscriptSource { bilingual ? bilingualSource ?? singleSource : singleSource }`。`var translator: (any Translating)?`。
- 二言語の捕捉: 開始ごとに新しい `LanguageArbiter`、0.5 秒ごとの `tick()`（`flush(now: source.elapsed)`）、`.candidate` → `submit`、`.laneVolatile` → 直近の採用言語の仮文字を `volatileText` に。判定の採用候補を `TranscriptSegment(offset: captureOffset + start, text:, language:)` で追加し、翻訳キューへ。捕捉の終了・失敗・`finish` で `drain(now: source.elapsed)`。
- 翻訳キュー: 到着順に 1 件ずつ、成功で `withTranslation`、失敗は回数を数えて保持。`setForeground(true)` と `updateNotesNow()` で再試行。`finish` で最長 10 秒待つ。
- 要点のバッチ・未反映文字数は `japaneseSide` を使う。保存は新しい整形。
- Tests（`MeetingSessionTests`、`FakeTranslator`）: Review Focus の 5 件 + `notesInputUsesJapaneseSide`、`savedTranscriptContainsBothTexts`。

### Task 3: App — 会議タブ
- `PocketAgentApp`: `MeetingSession(source: SpeechCapture(), bilingualSource: SpeechCapture(locales: [ja_JP, en_US]), translator: nil, ...)`。
- `MeetingView`: 開始画面に「二言語（日本語・English）」トグル（`@AppStorage("meeting.bilingual")`、開始時に `meeting.bilingual` へ反映）。二言語のとき翻訳データの導入状況（`AppleTranslator.isInstalled` 両方向）と「翻訳データを入手（日↔英）」（`.translationTask` + `prepareTranslation()`、検証画面と同じ箱渡し）。開始時、両方向導入済みなら `meeting.translator = AppleTranslator()`、未導入なら nil と案内文。録音中の文字起こしは二言語なら 2 列（行ごとに揃える。原文セルは太字、訳待ちは「…」）。
- Docs: ADR-038（段階 B をゲート前に組み込み、既定 OFF）、チェックリスト、test-plan。
