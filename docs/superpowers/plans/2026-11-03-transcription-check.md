# Transcription Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A one-button in-app transcription accuracy check: read a built-in passage aloud and see its character error rate (CER) on the spot.

**Architecture:** Core gains `TranscriptionScorer` (CER with the same normalization rules as `tools/cer.py`) and `TranscriptionCheckPassage` (the three fixed passages). The app adds a section to the existing verification area that records with the existing `SpeechCapture`, scores with Core, shows the CER and the raw result, and writes a `cer.*` line to the measurement log.

**Tech Stack:** Swift, SwiftUI, Swift Testing, GitHub Actions Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-03-transcription-check-design.md`

## Global Constraints

- Score with the same normalization as `tools/cer.py`: NFKC, then remove whitespace and the same punctuation set. Known pairs verified against `tools/cer.py` must agree.
- Never store audio. The measurement log receives counts and the CER only, never the transcript body (ADR-026).
- Journal capture path only. The meeting path stays a manual checklist item in `docs/phase0-checklist.md`.
- Passages are the fixed, non-sensitive texts from `docs/verification/2026-11-03-transcription-accuracy-baseline.md`.

## Review Focus

- The scorer agrees with `tools/cer.py` on the known pairs (identical text, substitution plus deletion, digit notation variance).
- A passage whose reference normalizes to empty yields no score instead of a crash or a fake zero.
- The verification section never writes the transcript or the passage into the measurement log, and never saves the recorded audio.

---

### Task 1: Core scorer and passages

**Files:**
- Create: `Packages/PocketAgentCore/Sources/PocketAgentCore/TranscriptionScorer.swift`
- Test: `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/TranscriptionScorerTests.swift`

**Interfaces:**
- Produce: `TranscriptionScorer.normalize(_:) -> String`, `TranscriptionScorer.editDistance(_:_:) -> Int`, `TranscriptionScorer.cer(reference:hypothesis:) -> Double?` (`nil` when the normalized reference is empty).
- Produce: `TranscriptionCheckPassage: CaseIterable` with `label: String` and `text: String` for the three fixed passages.

- [x] **Step 1: Write failing tests** for the known pairs from the `tools/cer.py` verification (identical text scores 0; 「今日は良い天気です。」 vs 「今日は良い天気だ」 is 2/9; 「３千億円と、午前１０時。」 vs 「三千億円と午前10時」 is 1/10; punctuation-only differences score 0; a punctuation-only reference yields `nil`), plus three passages with non-trivial texts.
- [x] **Step 2: Verify RED** with an iOS CI run on the pull request at a test-only commit; expect the new tests to fail because the scorer does not exist yet.
- [x] **Step 3: Implement** `TranscriptionScorer` and `TranscriptionCheckPassage` in Core (Foundation only).
- [x] **Step 4: Verify GREEN** with a full iOS CI run; expect package tests, both builds and simulator tests to pass.
- [x] **Step 5: Commit** the tested scorer.

### Task 2: Verification section in the app

**Files:**
- Modify: the existing verification view (the section list that hosts the MLX verification and measurement log)
- Reuse: `App/PocketAgent/Speech/SpeechCapture.swift`, the measurement log writer

**Interfaces:**
- Consume: `TranscriptionScorer.cer(reference:hypothesis:)` and `TranscriptionCheckPassage.allCases` from Task 1.
- Produce: a "文字起こし精度チェック" section: passage picker (A/B/C with the text shown), record/stop, then CER and the raw transcript; appends `cer.journal passage=<label> cer=<value> ref=<n> hyp=<n>` to the measurement log.

- [x] **Step 1: Write failing tests** where the flow can be tested without audio (scoring a fixed transcript against a passage, log line format).
- [x] **Step 2: Verify RED** with an iOS CI run on the pull request.
- [x] **Step 3: Implement** the section, wiring `SpeechCapture` final results into the scorer.
- [x] **Step 4: Verify GREEN** with a full iOS CI run.
- [ ] **Step 5: Commit**, and add the real-device check (screen CER equals `tools/cer.py` on the same transcript) to `docs/phase0-checklist.md` under 実機で未検証.

### Task 3: Docs

**Files:**
- Modify: `docs/verification/2026-11-03-transcription-accuracy-baseline.md`
- Modify: `docs/phase0-checklist.md`

- [ ] **Step 1:** Make the in-app check the primary procedure in the baseline doc; keep the script flow as the cross-check.
- [ ] **Step 2:** Register the baseline measurement (journal path, passages A–C) in the checklist's 実機で未検証 with the in-app procedure.
