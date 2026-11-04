# Transcription Auto Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** One-button automatic transcription accuracy check: bundled synthesized readings of the fixed passages are fed to the same SpeechAnalyzer configuration as the live path, scored, and logged with a `src=synth` marker — no human reading aloud.

**Architecture:** The synthesized WAVs (VOICEVOX, 16kHz mono) ship as base64 text resources and are restored to WAV files in the caches directory at runtime. A small runner builds a `SpeechTranscriber` with the live path's settings, converts the file audio to `SpeechAnalyzer.bestAvailableAudioFormat`, streams it into a `SpeechAnalyzer`, joins the final results, and hands the text to the existing `TranscriptionCheck.evaluate` (extended with a source marker). The verification screen gains an 「自動チェック」 button that runs A→B→C in order.

**Tech Stack:** Swift, SwiftUI, Swift Testing, Speech / AVFoundation, GitHub Actions Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-04-transcription-auto-check-design.md`

**CI:** RED run 41661035244（テストのみのコミットで単体テストのステップだけ失敗）→ GREEN run 41664296506（全ステップ成功、PR #7）

## Global Constraints

- Never store audio or transcript text in the measurement log: counts and CER only (ADR-026). The bundled audio is synthesized speech of the fixed passages only; no real voice.
- The auto check uses the same transcriber settings as the journal live path (locale resolution and `.progressiveTranscription` preset included), so the numbers stay comparable.
- The manual read-aloud check keeps working unchanged; its log lines stay unmarked. Synthesized results are marked `src=synth`.
- Real recognition (`SpeechAnalyzer` on audio) is verified on a real device only; CI covers the pure logic and the bundled assets.

## Review Focus

- The auto check cannot run at the same time as the manual recording, and vice versa.
- A failure on one passage (missing asset, no assets installed, recognition error) is reported for that passage and does not silently skip the rest.
- The restored WAV bytes are exactly the synthesized files (round-trip verified when the assets were generated, header/duration checked in tests).

---

### Task 1: Audio assets

**Files:**
- Create: `App/PocketAgent/Speech/CheckAudio/passage-a.wav.b64`, `passage-b.wav.b64`, `passage-c.wav.b64`
- Source of truth: `TranscriptionCheckPassage` texts (extracted mechanically, never retyped)

- [x] **Step 1: Synthesize** each passage with the local VOICEVOX engine (speaker 3 = ずんだもん ノーマル, speedScale 1.0) and resample to 16kHz mono 16-bit WAV.
- [x] **Step 2: Verify** durations and sizes (A 16.4s / B 15.8s / C 17.3s, about 0.5MB each), base64-encode, and confirm the encoded text decodes back to the identical WAV bytes.
- [x] **Step 3: Cross-check** the synthesized texts against `docs/verification/2026-11-03-transcription-accuracy-baseline.md` (verbatim).

### Task 2: Scoring source marker and audio asset mapping/restore

**Files:**
- Modify: `App/PocketAgent/Speech/TranscriptionCheck.swift` (add a source parameter; `src=synth` suffix for synthesized runs)
- Create: `App/PocketAgent/Speech/TranscriptionCheckAudio.swift` (passage → resource name, base64 restore to a WAV file URL)
- Test: `App/PocketAgentTests/TranscriptionCheckTests.swift` (synth log line), `App/PocketAgentTests/TranscriptionAutoCheckTests.swift` (mapping, bundled assets present, restored WAV is valid)

- [x] **Step 1: Write failing tests** for the synth log line format and for the asset mapping/restore.
- [x] **Step 2: Verify RED** with an iOS CI run on the pull request at a test-only commit.
- [x] **Step 3: Implement** the source parameter and `TranscriptionCheckAudio`.
- [x] **Step 4: Verify GREEN** with a full iOS CI run.

### Task 3: Auto check runner and screen

**Files:**
- Create: `App/PocketAgent/Speech/TranscriptionAutoChecker.swift` (file → same-settings transcriber → transcript; typed errors with user-facing messages)
- Modify: `App/PocketAgent/Views/MLXValidationView.swift` （自動チェック button, progress, per-passage CER/transcript/error in the existing section)
- Modify: `project.yml` (bundle `App/PocketAgent/Speech/CheckAudio` as resources)

- [x] **Step 1: Implement** the runner: restore the WAV, resolve the locale like the live path, install assets via `AssetInventory` when missing, convert to the analyzer format, stream the buffers, join final results.
- [x] **Step 2: Wire the screen**: run A→B→C in order, show progress and each result, append each `cer.journal … src=synth` line to the measurement log, keep manual controls mutually exclusive.
- [x] **Step 3: Verify GREEN** with a full iOS CI run (builds + simulator tests; recognition itself stays a device check).

### Task 4: Docs

**Files:**
- Modify: `docs/decisions.md` (ADR-044)
- Create: `docs/verification/2026-11-04-transcription-auto-check.md` (device procedure)
- Modify: `docs/phase0-checklist.md` (register the device checks under 実機で未検証）
- Modify: `docs/verification/2026-11-03-transcription-accuracy-baseline.md` (log format: `src=synth` marker and how to read the two series)

- [x] **Step 1:** Write ADR-044 and the device procedure; register the checklist items.
