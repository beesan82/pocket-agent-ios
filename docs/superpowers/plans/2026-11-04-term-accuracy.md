# Term Accuracy Experiments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the technical-term errors of fixed passage C (baseline: CER 8.64% on the ADR-046 series, 4 of 4 target terms wrong) by first re-ranking the speech engine's alternative transcriptions against a term list, and then, for whatever remains, applying a guarded correction dictionary — each step measured ON/OFF with the in-app auto check before any adoption.

**Architecture:** All decision logic lives in PocketAgentCore as pure, CI-testable functions: a term list (`TranscriptionTerms`), an alternative selector (`AlternativeSelector`) and a term corrector (`TermCorrector`). The App layer only extracts candidate strings from `SpeechTranscriber.Result` and applies the Core verdicts. Experiments run inside the verification screen's auto check behind an explicit ON/OFF switch; the live path's transcriber configuration changes only when an experiment is adopted, and then the auto check and the live path change together (ADR-044 comparability rule).

**Tech Stack:** Swift, SwiftUI, Swift Testing, Speech / AVFoundation, GitHub Actions Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-04-term-accuracy-design.md`

**CI:** RED: run 41840522226 (PR #10; Core package tests only, failing as expected). The first two implementation runs failed the simulator build on the composed options' type: run 41842185686 annotated it `SpeechTranscriber.ReportingOptions` (no such type), run 41844203003 annotated it `SpeechTranscriber.ReportingOption` (the enum case type — still not the property's type). Apple DocC declarations settled it: `Preset.reportingOptions` and the full initializer take `Set<SpeechTranscriber.ReportingOption>` (each option group is a Set of enum cases). GREEN: run 41847684876 (PR #10, every step successful). Experiment 2 adoption into the live path (Task 8): RED run 42049556248 (temporary PR #13 reproducing the test-only state — PR #12's own first run, 42042582698, was cancelled by the branch concurrency during the simulator build, before the unit-test step, so RED was re-confirmed on the temporary branch). GREEN: run 42044719928 (PR #12, every step successful).

## Global Constraints

- Fixed passages A–C stay frozen; scoring stays on the ADR-046 series. Additional technical-term passages, if ever made, live in a separate experiment-only set (E1–E3) and never join the A–C series.
- Measurement logs hold counts and CER only — never transcript text or target terms (ADR-026). Correction counts follow the same rule.
- Corrections and re-ranking apply to final results only; volatile results pass through unchanged.
- Real recognition (`SpeechAnalyzer` on audio) is verified on a real device only; CI covers the pure logic (selector, corrector, term list) and the option assembly.
- SDK facts are verified against the shipping SDK in CI builds, never guessed (repo rule). In particular, the exact option composition of the `.progressiveTranscription` preset is confirmed before building on it.
- The bilingual path is out of scope for these experiments (single-language journal / auto-check path only).

## Review Focus

- The selector must never replace the engine's top result when no candidate contains more listed terms (no gratuitous rewrites).
- The corrector's context-conditioned pairs must not fire on passages A or B; any firing there is treated as over-correction and blocks adoption.
- The auto check's standard configuration stays identical to the live path; the experiment switch is the only sanctioned divergence, and it is visible on screen.

---

### Task 0: Verify the SDK facts the design rests on

**Files:**
- Read only: SDK `Speech` module interface on the CI runner (Xcode 27), via a throwaway test target or a compile probe on a temporary branch (follow the AGENTS.md temporary-branch procedure for RED work).

- [x] **Step 1: Confirm the preset composition.** Print or assert the `transcriptionOptions` / `reportingOptions` / `attributeOptions` of `SpeechTranscriber.Preset.progressiveTranscription` and of `.transcriptionWithAlternatives`; record the result in this plan.
  - Recorded (CI run 41847684876, assertions and probe in `ProgressiveTranscriberTests`): `.progressiveTranscription` has no transcription options, reporting options = `volatileResults` + `fastResults`, and attribute options without `audioTimeRange`; the composed reporting options are exactly the preset's plus `alternativeTranscriptions`.
- [ ] **Step 2: Confirm the composed initializer works.** Build a transcriber from the progressive options plus `.alternativeTranscriptions` in `reportingOptions` and confirm `result.alternatives` is populated for a final result (device or simulator probe; if the simulator cannot transcribe, record it as a device-check item instead).
  - Recorded: the composed initializer builds in CI (run 41847684876). Whether alternatives are actually populated needs real recognition, which the simulator cannot do here, so it is recorded as a device-check item (docs/phase0-checklist.md, ADR-047 section) and is covered by the Task 4 device run.

### Task 1: Term list in Core

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/TranscriptionTerms.swift`
- Create: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/TranscriptionTermsTests.swift`

- [x] **Step 1: Write the failing tests.** The list contains the four target terms （露光装置， 歩留まり, 線幅， 規格） and the surrounding semiconductor terms from the spec; a `countOccurrences(in:)` helper counts listed terms in a normalized string.
- [x] **Step 2: Confirm RED** on a temporary branch (packages-only CI), then implement and confirm GREEN.
  - Recorded: RED in PR #10's first CI (run 41840522226), GREEN in run 41847684876.

### Task 2: Alternative selector in Core (Experiment 1 logic)

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/AlternativeSelector.swift`
- Create: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/AlternativeSelectorTests.swift`

- [x] **Step 1: Write the failing tests.** Cases: a candidate containing 露光装置 beats a top result containing 路行装置； equal term counts keep the original text; among winning candidates the smallest edit distance to the original wins; empty alternatives return the original; normalization matches the scorer's (ADR-046 series).
- [x] **Step 2: Confirm RED**, implement the selector per the spec's evaluation/adoption rules, confirm GREEN.
  - Recorded: RED in run 41840522226, GREEN in run 41847684876.

### Task 3: Wire alternatives into the auto check behind an experiment switch

**Files:**
- Modify: `App/PocketAgent/Speech/TranscriptionAutoChecker.swift` (build the transcriber from composed options when the experiment is ON; return per-result candidates in addition to the joined text)
- Modify: `App/PocketAgent/Speech/SpeechCapture.swift` (`AudioPipeline.make` gains the same composed-options builder, used only when adopted — in this task only the shared builder is extracted, defaults unchanged)
- Modify: the verification screen's auto-check section (experiment ON/OFF switch, per-passage display of term-error count and candidate hit count next to the CER)

- [x] **Step 1: Failing tests first** for the pure parts (option assembly produces reporting options including `.alternativeTranscriptions` only when ON; candidate extraction from a result-shaped value). Real recognition stays device-verified.
- [x] **Step 2: Implement**, keeping the OFF configuration byte-identical to today's (`.progressiveTranscription` semantics), then CI GREEN.
  - Recorded: the shared builder is `ProgressiveTranscriber` (`makeStandard` = the preset itself, used by both the live pipeline and the standard auto check; `make` = the composed options, used only by the experiment). Runs 41842185686 and 41844203003 failed on the composed options' type (see the CI line above); GREEN in run 41847684876.

### Task 4: Measure Experiment 1 on device and judge

**Files:**
- Modify: `docs/verification/2026-11-03-transcription-accuracy-baseline.md` (record ON/OFF values), `docs/phase0-checklist.md` (device-check entry)

- [x] **Step 1: Device run.** Auto check with the experiment OFF and ON for A–C; record C's CER and term-error count (target 4 → ≤2, CER ≤ ~5%), A/B regression check (A 2.44% / B 0.00% must not worsen), ON/OFF duration comparison, and how often the target terms appeared in the alternatives at all.
  - Recorded (2026-11-05, iPhone 15, TestFlight build of main 5216912 / Codemagic build 6aebb41a, experiment ON): A — CER OFF 2.44% / ON 2.44%, term errors 0 → 0, candidate target hits 0. B — CER OFF 0.00% / ON 0.00%, term errors 0 → 0, hits 0. C — CER OFF 8.64% / ON 8.64%, term errors 4 → 4, hits 0. No A/B regression (nothing changed at all). The ON/OFF duration comparison was not captured in the device report and remains unmeasured.
- [x] **Step 2: Judge by the spec's criteria.** Adopt → Task 5. No term ever appears in alternatives → record "no-show" and go to Task 6. Otherwise record rejection with the numbers.
  - Recorded: no-show. Across all three passages the alternatives never contained a single target term (candidate target hits 0 everywhere), so the selector had nothing to adopt. Experiment 1 is **not adopted**; Task 5 is skipped and the work proceeds to Task 6 (Experiment 2), per the spec's judgment criteria.

### Task 5: Adopt Experiment 1 into the live path (only if Task 4 adopts)

> Recorded (2026-11-05): skipped — Task 4 judged Experiment 1 a no-show and did not adopt it, so the live path keeps the standard configuration.

**Files:**
- Modify: `App/PocketAgent/Speech/SpeechCapture.swift` (single-language path uses the composed options and applies the selector to final results before emitting `.final` events)
- Modify: `docs/decisions.md` (register ADR-047 with the measured outcome)

- [ ] **Step 1: TDD** for the final-result application point (selector applied once per final result, volatile untouched), CI GREEN.
- [ ] **Step 2: Device check** with the manual read-aloud of passage C (real voice) to confirm no regression outside synthesized speech; record in `docs/phase0-checklist.md`.

### Task 6: Term corrector in Core (Experiment 2 logic)

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/TermCorrector.swift`
- Create: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/TermCorrectorTests.swift`

- [x] **Step 1: Write the failing tests.** Unconditional pairs （路行装置→露光装置, ぶどまり→歩留まり） fire anywhere in a final text; context-conditioned pairs （企画→規格, 先幅→線幅） fire only with their context condition and never on the A/B passage texts; the corrector returns the corrected text plus a count (counts only — no text — is what callers may log).
- [x] **Step 2: Confirm RED**, implement with per-pair ON/OFF, confirm GREEN. Any pair whose context condition cannot be made precise is dropped, not shipped fuzzy.
  - Recorded: RED in run 41931972086 (PR #11; the commit's only change is the Core test file referencing the not-yet-existing `TermCorrector`). GREEN in run 41932238853 (PR #11).
  - Context conditions, as registered in `TermCorrector`: 企画→規格 fires only when the text immediately after 企画 starts with を超え / が超え / 外 / 値 (spec collocations: a limit exceeded, out-of-spec, a spec value — a "project/plan" never takes these continuations). 先幅→線幅 fires only before measurement collocations （のばらつき / の変動 / の均一 / の精度 / の測定 / の管理 / を測定 / を管理 / がばらつ）. Both conditions could be made precise against the observed error and ordinary usage, so both pairs are registered; the per-pair switch (`disabledRuleIDs`) remains the escape hatch if the device measurement shows over-correction.

### Task 7: Measure Experiment 2 in the auto check and judge

**Files:**
- Modify: auto-check wiring (apply the corrector after selection when the Experiment 2 switch is ON; show the correction count on screen), `docs/verification/2026-11-03-transcription-accuracy-baseline.md`, `docs/phase0-checklist.md`

- [x] **Step 1: Device run.** A–C with Experiment 2 OFF/ON (on top of the Experiment 1 outcome); record C's CER (target ≤5%) and term-error count (target 4 → ≤1), and confirm zero corrector firings on A and B.
  - Wiring recorded (PR #11): the auto check gained an Experiment 2 switch (`TranscriptionExperiment.evaluateDictionary`); ON applies the corrector per final segment on top of the Experiment 1 selection when both switches are on, displays the OFF/ON CER, term errors and firing count, and logs the `dict=on` line.
  - Recorded (2026-11-05, iPhone 15, TestFlight build #24 (main 891601d, Codemagic build 6aec8758ab17f8deb7530e97), dictionary ON): A — CER OFF 2.44% / ON 2.44%, term errors 0 → 0, dictionary firings 0. B — CER OFF 0.00% / ON 0.00%, term errors 0 → 0, firings 0. C — CER ON 0.00%; the screenshot of the corrected transcript shows all four observed errors （路行装置・ぶどまり・先幅・企画） corrected, so term errors 4 → 0. C's OFF-side numbers were not visible in this run's screenshot and are not recorded here; the dictionary-less C value under identical conditions (same synthesized audio, same settings) is the Experiment 1 run's 8.64%, cited as a reference only — it is not this run's measurement. C's firing count in the log was likewise not captured and is not recorded.
- [x] **Step 2: Judge by the spec's criteria.** Adopt (possibly reduced to unconditional pairs only) → apply to the live path's final results like Task 5 and register the outcome in ADR-047's follow-up note; reject → record the numbers and stop, per the spec's "both rejected" clause.
  - Recorded: **adopted** — every criterion is met (term errors 4 → 0, against a target of ≤1; C's CER 0.00%, against ≤5%; zero firings on A and B, so no reduction to unconditional pairs only). The live-path application is Task 8; the outcome is registered in ADR-047's follow-up note and in the baseline document.

### Task 8: Adopt Experiment 2 into the live path (adoption per Task 7's judgment)

**Files:**
- Modify: `App/PocketAgent/Speech/SpeechCapture.swift` (single-language finals pass through `TermCorrector` via `SpeechCapture.correctFinalText`; firing counts kept as counts only)
- Modify: `App/PocketAgent/Views/MLXValidationView.swift` (the dictionary switch keeps its OFF/ON comparison and journal format, defaults ON to match the live path, and is labelled as adopted; the 30-second speech test log line gains the live firing count)
- Create: `App/PocketAgentTests/LiveTermCorrectionTests.swift`

- [x] **Step 1: TDD** for the final-result application point (corrector applied once per final result on the single-language path, volatile untouched), CI GREEN.
  - Recorded: RED run 42049556248 (temporary PR #13; see the CI line at the top for why RED was re-confirmed off-PR), GREEN run 42044719928 (PR #12, every step successful, including the simulator unit tests with `LiveTermCorrectionTests`).
- [ ] **Step 2: Device checks.** Real-voice manual check of passage C on the adopted path (no regression outside synthesized speech) and a live-path firing check via the validation screen's speech test. The bilingual path stays uncorrected: it finalizes text in `MeetingSession` through `LanguageArbiter` and shares no finalization point with the single-language path, so its interaction with the dictionary needs its own design. Recorded in docs/phase0-checklist.md.

---

## Notes for the implementer

- The four target terms and the C-passage error pairs in the spec were observed on synthesized speech (VOICEVOX) through the file-fed path. Real-voice errors may differ; that is what the manual C check in Task 5 / Task 7 is for.
- `ConfidenceMath` (Core, in `LanguageArbiter.swift`) is the existing precedent for putting small speech-math helpers in Core with package tests.
