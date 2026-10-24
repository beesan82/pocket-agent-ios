# 会議の言語選択（言語 1・言語 2、中国語追加）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 会議タブで「言語 1」（日本語・English・中文、既定 日本語）と「言語 2」（なし＋言語 1 以外、既定 なし）を選び、選んだ組み合わせで二言語会議（自動判定・端末内翻訳・2 列）または単一言語の会議ができるようにする。中国語は普通話・簡体字（zh-CN）。

**Architecture:** 言語の表は Core の `MeetingLanguage.all`（コード・表示名・ロケール・全文の印）の 1 か所。`LanguageArbiter(languages:)` が組み合わせを知り、文字種の推定は `ScriptGuess.language(of:among:)`（かなあり→ja、漢字中心→zh か ja、その他→en）。`TranscriptSegment` は訳文の言語（`translationLanguage`）を持ち、要点の入力 `japaneseSide` は「日本語の原文、日本語への訳文、なければ原文」。`MeetingSession` は `setLanguages([String])` と、言語コード列から捕捉を作るファクトリ（同じ組み合わせは使い回し）を持つ。`SpeechAvailability` は言語ごとの可否を一般化。

**Spec:** ユーザーとの会話（2026-10-24）: 「中国語も対象に追加したい」「二言語かな」「組み合わせ選択できるようにするのがベター」「選択肢は 2 つの項目で選ぶ。言語が増えたら大変」。要点は日本語のまま（作り手の判断）。繁体字は対象外。

## Global Constraints
- 言語 1 だけ（言語 2 = なし）のときは単一言語の捕捉（翻訳なし・1 列）。言語 1 が日本語以外でもよい（English だけの会議など）。
- 日本語を含む組み合わせでは、日本語以外の発言は日本語訳を待ってから要点に入れる（従来どおり）。日本語を含まない組み合わせ（English・中文）では原文のまま要点のモデルに渡す（要点は日本語で書かれる）。
- 全文の印: 日本語なし、English `(EN) `、中文 `(ZH) `（表の値）。
- 既存の「二言語」スイッチ ON（`meeting.bilingual`）の利用者は、初回に 言語 2 = English へ移行する。
- 検証画面（日英ゲート）は変えない。
- RED は一時ブランチ、main には GREEN のみ。

## Review Focus
1. 日本語と中国語は漢字を共有 → 信頼度なしの判定は「かなの有無」で分ける（`scriptGuessSeparatesJapaneseAndChinese`）。
2. English だけの会議 → セグメントの言語が en、翻訳なし（`singleNonJapaneseLanguageTagsSegments`）。
3. English・中文 → 翻訳は相手言語へ、要点は原文で訳を待たない（`pairWithoutJapaneseUsesOriginalsForNotes`）。
4. 日本語・中文 → 中文の発言は和訳、日本語の発言は中訳（`japaneseChinesePairTranslatesBothWays`）。
5. 言語の変更は会議中は無視（既存 `languageChoiceIsFixedWhileAMeetingIsOpen` を `setLanguages` でも）。

### Task 1: Core
- `MeetingLanguage`（`code`, `displayName`, `localeIdentifier`, `transcriptMark`; `static let all`; `static func named(_:)`）。
- `ScriptGuess.language(of:among:)`、既存 `language(of:)` は `among: ["ja", "en"]`。
- `LanguageArbiter.init(languages: [String] = ["ja", "en"])`。単独判定と同点の決着は `among: languages`。
- `TranscriptSegment.translationLanguage`（訳文があり未指定なら旧来の推定: ja→en、それ以外→ja）、`withTranslation(_:language:)`、`japaneseSide` は日本語訳のときだけ訳文。`otherLanguage` は削除。全文の印は表から。
- Tests: `scriptGuessSeparatesJapaneseAndChinese`、`arbiterUsesItsLanguagesForScriptDecisions`、`chineseMarkAndTranslationLanguage`、`japaneseSideOnlyUsesJapaneseTranslations`。

### Task 2: App — MeetingSession と捕捉
- `SpeechAvailability.reason(isAvailable:languages:permissionGranted:)`（言語ごとの `(code, supported, installed)`、順序: モジュール → 非対応（言語順）→ データ未導入（言語順）→ 権限）。`SpeechUnavailableReason` に `.languageUnsupported(String)`, `.languageAssetsNotInstalled(String)`（表示名入りの文言）を追加し、英語専用の 2 件を置き換える。日本語は従来の文言のまま。
- `SpeechCapture.refreshAvailability` は全ロケールを一般化した判定で。
- `MeetingSession`: `languages: [String]`（既定 `["ja"]`）、`setLanguages(_:)`、`bilingual` は `languages.count == 2`。`init(makeSource:...)` と、テスト用に従来の `init(source:bilingualSource:...)`（2 言語なら bilingualSource、1 言語なら source を返すファクトリ）。単一言語の `.final` は言語 1 を付ける。翻訳先は組み合わせの相手。要点の待ちは「組み合わせに日本語があり、その発言が日本語以外」のときだけ。
- Tests（`BilingualMeetingTests` に追加）: Review Focus 2〜5。

### Task 3: App — 会議タブ
- `@AppStorage("meeting.language1")`（既定 "ja"）、`@AppStorage("meeting.language2")`（既定 ""）と 2 つの `Picker`。旧 `meeting.bilingual` の移行。
- 列見出しと列の言語は組み合わせから。翻訳データの導入状況・入手ボタンは組み合わせの両方向。音声データの確認文言は選んだ言語名で。
- `PocketAgentApp`: `MeetingSession(makeSource: { codes in SpeechCapture(locales: codes.compactMap { MeetingLanguage.named($0)?.locale }) }, ...)`。
- Docs: ADR-039、チェックリスト。
