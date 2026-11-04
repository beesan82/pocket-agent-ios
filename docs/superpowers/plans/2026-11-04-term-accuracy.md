# Term Accuracy Experiments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the technical-term errors of fixed passage C (baseline: CER 8.64% on the ADR-046 series, 4 of 4 target terms wrong) by first re-ranking the speech engine's alternative transcriptions against a term list, and then, for whatever remains, applying a guarded correction dictionary — each step measured ON/OFF with the in-app auto check before any adoption.

**Architecture:** All decision logic lives in PocketAgentCore as pure, CI-testable functions: a term list (`TranscriptionTerms`), an alternative selector (`AlternativeSelector`) and a term corrector (`TermCorrector`). The App layer only extracts candidate strings from `SpeechTranscriber.Result` and applies the Core verdicts. Experiments run inside the verification screen's auto check behind an explicit ON/OFF switch; the live path's transcriber configuration changes only when an experiment is adopted, and then the auto check and the live path change together (ADR-044 comparability rule).

**Tech Stack:** Swift, SwiftUI, Swift Testing, Speech / AVFoundation, GitHub Actions Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-04-term-accuracy-design.md`

**CI:** RED: run 41840522226 (PR #10; Core package tests only, failing as expected). First implementation run 41842185686 failed the simulator build: the App layer annotated the option set as `ReportingOptions`, but the SDK's type is `SpeechTranscriber.ReportingOption` (singular — confirmed against Apple DocC, never guessed). GREEN: run 41844203003 (PR #10, every step successful).

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
  - Recorded (CI run 41844203003, assertions and probe in `ProgressiveTranscriberTests`): `.progressiveTranscription` has no transcription options, reporting options = `volatileResults` + `fastResults`, and attribute options without `audioTimeRange`; the composed reporting options are exactly the preset's plus `alternativeTranscriptions`.
- [ ] **Step 2: Confirm the composed initializer works.** Build a transcriber from the progressive options plus `.alternativeTranscriptions` in `reportingOptions` and confirm `result.alternatives` is populated for a final result (device or simulator probe; if the simulator cannot transcribe, record it as a device-check item instead).
  - Recorded: the composed initializer builds in CI (run 41844203003). Whether alternatives are actually populated needs real recognition, which the simulator cannot do here, so it is recorded as a device-check item (docs/phase0-checklist.md, ADR-047 section) and is covered by the Task 4 device run.

### Task 1: Term list in Core

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/TranscriptionTerms.swift`
- Create: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/TranscriptionTermsTests.swift`

- [x] **Step 1: Write the failing tests.** The list contains the four target terms （露光装置， 歩留まり, 線幅， 規格） and the surrounding semiconductor terms from the spec; a `countOccurrences(in:)` helper counts listed terms in a normalized string.
- [x] **Step 2: Confirm RED** on a temporary branch (packages-only CI), then implement and confirm GREEN.
  - Recorded: RED in PR #10's first CI (run 41840522226), GREEN in run 41844203003.

### Task 2: Alternative selector in Core (Experiment 1 logic)

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/AlternativeSelector.swift`
- Create: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/AlternativeSelectorTests.swift`

- [x] **Step 1: Write the failing tests.** Cases: a candidate containing 露光装置 beats a top result containing 路行装置； equal term counts keep the original text; among winning candidates the smallest edit distance to the original wins; empty alternatives return the original; normalization matches the scorer's (ADR-046 series).
- [x] **Step 2: Confirm RED**, implement the selector per the spec's evaluation/adoption rules, confirm GREEN.
  - Recorded: RED in run 41840522226, GREEN in run 41844203003.

### Task 3: Wire alternatives into the auto check behind an experiment switch

**Files:**
- Modify: `App/PocketAgent/Speech/TranscriptionAutoChecker.swift` (build the transcriber from composed options when the experiment is ON; return per-result candidates in addition to the joined text)
- Modify: `App/PocketAgent/Speech/SpeechCapture.swift` (`AudioPipeline.make` gains the same composed-options builder, used only when adopted — in this task only the shared builder is extracted, defaults unchanged)
- Modify: the verification screen's auto-check section (experiment ON/OFF switch, per-passage display of term-error count and candidate hit count next to the CER)

- [x] **Step 1: Failing tests first** for the pure parts (option assembly produces reporting options including `.alternativeTranscriptions` only when ON; candidate extraction from a result-shaped value). Real recognition stays device-verified.
- [x] **Step 2: Implement**, keeping the OFF configuration byte-identical to today's (`.progressiveTranscription` semantics), then CI GREEN.
  - Recorded: the shared builder is `ProgressiveTranscriber` (`makeStandard` = the preset itself, used by both the live pipeline and the standard auto check; `make` = the composed options, used only by the experiment). First run 41842185686 failed on the option-set type name (see the CI line above); GREEN in run 41844203003.

### Task 4: Measure Experiment 1 on device and judge

**Files:**
- Modify: `docs/verification/2026-11-03-transcription-accuracy-baseline.md` (record ON/OFF values), `docs/phase0-checklist.md` (device-check entry)

- [ ] **Step 1: Device run.** Auto check with the experiment OFF and ON for A–C; record C's CER and term-error count (target 4 → ≤2, CER ≤ ~5%), A/B regression check (A 2.44% / B 0.00% must not worsen), ON/OFF duration comparison, and how often the target terms appeared in the alternatives at all.
- [ ] **Step 2: Judge by the spec's criteria.** Adopt → Task 5. No term ever appears in alternatives → record "no-show" and go to Task 6. Otherwise record rejection with the numbers.

### Task 5: Adopt Experiment 1 into the live path (only if Task 4 adopts)

**Files:**
- Modify: `App/PocketAgent/Speech/SpeechCapture.swift` (single-language path uses the composed options and applies the selector to final results before emitting `.final` events)
- Modify: `docs/decisions.md` (register ADR-047 with the measured outcome)

- [ ] **Step 1: TDD** for the final-result application point (selector applied once per final result, volatile untouched), CI GREEN.
- [ ] **Step 2: Device check** with the manual read-aloud of passage C (real voice) to confirm no regression outside synthesized speech; record in `docs/phase0-checklist.md`.

### Task 6: Term corrector in Core (Experiment 2 logic)

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/TermCorrector.swift`
- Create: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/TermCorrectorTests.swift`

- [ ] **Step 1: Write the failing tests.** Unconditional pairs （路行装置→露光装置, ぶどまり→歩留まり） fire anywhere in a final text; context-conditioned pairs （企画→規格, 先幅→線幅） fire only with their context condition and never on the A/B passage texts; the corrector returns the corrected text plus a count (counts only — no text — is what callers may log).
- [ ] **Step 2: Confirm RED**, implement with per-pair ON/OFF, confirm GREEN. Any pair whose context condition cannot be made precise is dropped, not shipped fuzzy.

### Task 7: Measure Experiment 2 in the auto check and judge

**Files:**
- Modify: auto-check wiring (apply the corrector after selection when the Experiment 2 switch is ON; show the correction count on screen), `docs/verification/2026-11-03-transcription-accuracy-baseline.md`, `docs/phase0-checklist.md`

- [ ] **Step 1: Device run.** A–C with Experiment 2 OFF/ON (on top of the Experiment 1 outcome); record C's CER (target ≤5%) and term-error count (target 4 → ≤1), and confirm zero corrector firings on A and B.
- [ ] **Step 2: Judge by the spec's criteria.** Adopt (possibly reduced to unconditional pairs only) → apply to the live path's final results like Task 5 and register the outcome in ADR-047's follow-up note; reject → record the numbers and stop, per the spec's "both rejected" clause.

---

## Notes for the implementer

- The four target terms and the C-passage error pairs in the spec were observed on synthesized speech (VOICEVOX) through the file-fed path. Real-voice errors may differ; that is what the manual C check in Task 5 / Task 7 is for.
- `ConfidenceMath` (Core, in `LanguageArbiter.swift`) is the existing precedent for putting small speech-math helpers in Core with package tests.
