# 二言語ゲート（段階 A）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MLX 検証画面で、日本語と英語の認識器を同時に回したときの言語判定の分かれ方・遅延・メモリと、端末内翻訳の速さを iPhone 15 で 1 画面のスクリーンショットに残せるようにする。

**Architecture:** 言語判定（`LanguageArbiter`）、信頼度の平均、文字種による推定、計測の集計と表示行は Core の純粋ロジック。App では `SpeechCapture(locales:)` が複数ロケールのとき 1 本のマイク tap から各ロケールの `SpeechAnalyzer` に同じ音声を流し、確定結果を信頼度付きの候補イベントとして出す（単一ロケールの動きは変えない）。翻訳は `Translating`（Core）を `AppleTranslator`（App、`TranslationSession(installedSource:target:)`）が実装。検証画面に「二言語」節を足す。

**Tech Stack:** Swift 6 / SwiftUI / Speech (SpeechAnalyzer, SpeechTranscriber, `AttributeScopes.SpeechAttributes.transcriptionConfidence`) / Translation (`TranslationSession`, `LanguageAvailability`, `.translationTask`) / swift-testing

**Spec:** `docs/superpowers/specs/2026-10-23-bilingual-meeting-design.md`（段階 A のみ）

## Global Constraints
- Core は Foundation のみ。Speech / Translation / AVFoundation は App だけ。
- 単一ロケール（既定 `[ja_JP]`）の `SpeechCapture` の動作・イベントは変えない（会議モードと日誌の音声入力が使う）。
- 二言語の transcriber は `SpeechTranscriber(locale:transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange, .transcriptionConfidence])`（`progressiveTranscription` 相当 + 時間範囲 + 信頼度。SDK の文書で確認済み）。
- 判定の定数: `holdSeconds = 1.5`、`acceptConfidence = 0.6`、`floorConfidence = 0.3`（ゲート結果で見直す）。重なり判定の許容 0.1 秒。判定済み区間は 30 秒保持。
- 翻訳は導入済みペアのみ `TranslationSession(installedSource:target:)` で行い、未導入なら `.translationTask` + `prepareTranslation()` の「翻訳データを入手」ボタン。シミュレータでは翻訳・音声を呼ばない（CI は build と純粋ロジックのテストのみ）。
- 画面の失敗文言は固定文のみ。計測サマリーの各行は 40 文字以内（既存 `MeasurementSummary` と同じ規則）。
- RED は一時ブランチ（`continue-on-error`）で確認し、main には GREEN だけ push（メモリ `red-runs-off-main`）。

## Review Focus
1. ja と en が同じ発話を違う区切りで返す（1 対多）→ 1 組として判定し、二重に出ない（Task 1 `oneToManyOverlapIsOneGroup`）。
2. 保留が切れて判定した後に、もう一方の系統の重なる確定が遅れて届く → 捨てる（Task 1 `lateOverlapIsDiscarded`）。
3. 両系統とも信頼度が低い（雑音・相づち）→ どちらも出さない（Task 1 `bothBelowFloorIsNoise`）。
4. 信頼度が nil → 文字種で決める（Task 1 `nilConfidenceUsesScript`）。
5. 停止時に保留中の候補が残る → すべて判定してから集計（Task 1 `drainDecidesEverything`）。

---

### Task 1: Core — 候補・判定・集計
**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/LanguageArbiter.swift`, `Packages/PocketAgentCore/Sources/PocketAgentCore/BilingualRunStats.swift`
- Test: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/LanguageArbiterTests.swift`, `BilingualRunStatsTests.swift`

**Interfaces (Produces):**
```swift
public struct LaneCandidate: Sendable, Equatable, Identifiable {
    public let id: UUID; public let language: String  // "ja" / "en"
    public let text: String; public let confidence: Double?  // 文字数で重み付けした平均
    public let start: TimeInterval; public let end: TimeInterval; public let arrivedAt: TimeInterval
}
public enum ConfidenceMath { static func weightedAverage(_ runs: [(characters: Int, confidence: Double?)]) -> Double? }
public enum ScriptGuess { static func japaneseRatio(_ text: String) -> Double; static func language(of text: String) -> String }  // ≥0.5 で "ja"
public struct ArbiterDecision: Sendable, Equatable {
    public enum Reason: Sendable, Equatable { case compared, single, noise, late }
    public let language: String?; public let accepted: [LaneCandidate]; public let rejected: [LaneCandidate]; public let reason: Reason
}
public struct LanguageArbiter: Sendable {
    public static let holdSeconds: TimeInterval = 1.5; acceptConfidence = 0.6; floorConfidence = 0.3
    public init()
    public mutating func submit(_ candidate: LaneCandidate) -> [ArbiterDecision]   // arrivedAt を現在時刻として期限切れも判定
    public mutating func flush(now: TimeInterval) -> [ArbiterDecision]
    public mutating func drain() -> [ArbiterDecision]
}
public struct BilingualRunStats: Equatable {
    public init(expected: String, decisions: [ArbiterDecision], minAvailableMB: Int?)
    public var groups: Int; matches: Int; jaConfidence: Double?; enConfidence: Double?; averageDelay: Double?
    public var lines: [String]  // 各 40 文字以内
}
```
判定の規則は spec「`LanguageArbiter` の規則」1〜7 のとおり。組の比較で両系統とも信頼度がある場合は高い方、片方が nil なら組の全文の `ScriptGuess.language`、両系統の平均がともに `floorConfidence` 未満なら `noise`。単独の組は信頼度 ≥ floor（nil は文字種が自言語なら採用）で `single`、それ以外 `noise`。遅れて届いた重なり候補は `late`（rejected に入れる）。`averageDelay` は accepted の `arrivedAt − end` の平均。`lines` の形式:
```
二言語 日本語 判定 4/5 一致
信頼度 ja 0.86 / en 0.21
遅延 平均 1.8 秒 / 最小空き 1200 MB
```
（英語テストは「二言語 英語 …」。未測定値は「未測定」）

- [ ] **Step 1: Write the failing tests**: `weightedAverageSkipsNil`（`[(4, 0.9), (2, nil), (4, 0.5)]` → 0.7、全 nil → nil）、`japaneseRatioAndGuess`（"納期は11月末" → ja、"That is fine" → en、"" → en）、`overlappingPairPicksHigherConfidence`、`oneToManyOverlapIsOneGroup`、`singleIsHeldThenAccepted`（flush(now: arrivedAt+1.4) は空、+1.5 で採用）、`lateOverlapIsDiscarded`、`bothBelowFloorIsNoise`、`nilConfidenceUsesScript`、`drainDecidesEverything`、`statsCountMatchesAndLines`。
- [ ] **Step 2: RED を一時ブランチで確認**（Core テストが型なしで失敗）
- [ ] **Step 3: Implement**
- [ ] **Step 4: GREEN**
- [ ] **Step 5: Commit** `feat(core): language arbiter and bilingual run stats`

### Task 2: App — 2 系統の SpeechCapture と翻訳
**Files:**
- Modify: `App/PocketAgent/Speech/SpeechAvailability.swift`（`englishUnsupported` / `englishAssetsNotInstalled` を追加。`reason(...)` に `supportsEnglish: Bool = true, englishAssetsInstalled: Bool = true` を追加。順序: module → ja 非対応 → en 非対応 → ja アセット → en アセット → 権限）、`App/PocketAgent/Speech/TranscriptSource.swift`（`case candidate(LaneCandidate)`）、`App/PocketAgent/Speech/SpeechCapture.swift`（`init(locales: [Locale] = [ja_JP])`。複数のとき: 可否は全ロケール、`installAssets` は全 transcriber をまとめて、`AudioPipeline` は transcriber・analyzer・入力ストリームを配列で持ち tap で全ストリームに yield、確定結果は `.candidate`、仮文字は `laneVolatile: [String: String]`（観測可能）に入れて `.volatile` は出さない）、`App/PocketAgent/Meeting/MeetingSession.swift`（`.candidate` は無視）
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/Translating.swift`（`public protocol Translating: Sendable { func translate(_ text: String, from: String, to: String) async throws -> String }`）、`App/PocketAgent/Speech/AppleTranslator.swift`（`final class AppleTranslator: Translating`。`static func isInstalled(from:to:) async -> Bool`（`LanguageAvailability().status(from:to:) == .installed`）、セッションはペアごとに遅延生成して保持）
- Test: `App/PocketAgentTests/SpeechAvailabilityTests.swift`（`reasonOrderWithEnglish`、`messagesAreJapaneseAndDistinct` に 2 件追加）

- [ ] RED（一時ブランチ）→ 実装 → CI で build（simulator・device）と全テスト GREEN → commit `feat(app): two-lane SpeechCapture with confidence candidates; Apple translator`

### Task 3: App — 検証画面の「二言語」節と記録
**Files:**
- Modify: `App/PocketAgent/Views/MLXValidationView.swift`（`@State bilingual = SpeechCapture(locales: [ja_JP, en_US])`、`Section("二言語")`）
- Create: `docs/bilingual-eval.md`（記入テンプレート）; Modify: `docs/phase0-checklist.md`（二言語ゲート節）, `docs/decisions.md`（ADR-035 二言語ゲートは 2 系統同時認識 + 信頼度比較で測る）

節の中身:
- 可否（`bilingual.reason?.userMessage ?? "利用可能"`）、「権限を確認」、「音声データを入手（日・英）」。
- 「日本語で話す 30 秒」「英語で話す 30 秒」（期待言語を決めて開始。停止ボタンあり。30 秒で自動停止）。実行中は 1 秒ごとに `DeviceProbes.availableMemoryBytes()` の最小値を記録、`.candidate` を `LanguageArbiter.submit`、0.5 秒ごとに `flush(now:)`、停止時 `drain()`。経過は録音開始からの秒（候補の `arrivedAt` も同じ時計）。
- 判定の一覧（言語の印、採用文、信頼度。捨てた側は薄く取り消し線、理由）。`laneVolatile` を薄く。
- 結果: `BilingualRunStats.lines` を等幅で（日本語テストと英語テストの最新結果を両方）。`measurementLog` にも 1 回分を追記。
- 翻訳: `AppleTranslator.isInstalled` で ja→en / en→ja を確認。未導入なら「翻訳データを入手」（`.translationTask(configuration)` で `prepareTranslation()`、ボタンで `configuration` を立てる）。「翻訳テスト」で固定 6 文（日本語 3・英語 3。会議の言い回し）を訳し、文ごとの秒と訳文、方向ごとの平均を表示し、`翻訳 ja→en 平均 0.8 秒` / `翻訳 en→ja 平均 0.9 秒` をログと結果に出す。

- [ ] 実装 → CI GREEN → docs → commit `feat(app): bilingual gate on the validation screen` → push → `gh run watch`
- [ ] ユーザーに TestFlight 起動と測定手順を伝える（`docs/bilingual-eval.md`）。
