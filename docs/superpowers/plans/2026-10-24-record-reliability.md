# Record Reliability Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; independent model/log domains may use superpowers:dispatching-parallel-agents. Track completion below.

**Goal:** Prevent stale summaries, report deletion failures, reject incomplete models, and recover journal drafts.
**Architecture:** Extend existing sessions and file stores; persist one journal draft locally; keep API and model backends unchanged.
**Tech Stack:** Swift 6, SwiftUI, Foundation, SwiftData, Swift Testing, existing macOS CI.
**Spec:** docs/superpowers/specs/2026-10-24-record-reliability-design.md

## Global Constraints
- No dependencies, no new cloud transfer; preserve valid existing model directories.
- Work only in the attached isolated worktree; do not change concurrent meeting/lookup implementations.
- Report Windows verification limits accurately. Run full CI on the actual branch before claiming verified.

## Review Focus
- Text changed during/after summarization: no mismatched body/transcript persisted.
- Partial summary and restored draft: incompleteness remains visible, no automatic model call on recovery.
- Failure to delete the on-disk log or draft: failure shown and retry remains possible.
- Missing tokenizer, empty/truncated weights, missing indexed shards: unavailable without network recovery.
- Save versus autosave, discard versus delayed updates: saved/discarded drafts do not reappear.

## Tasks
- [ ] 1. Add behavior tests for stale summary save and partial status; implement source tracking and UI warning in JournalCaptureSession/View.
- [ ] 2. Add filesystem failure tests for MeasurementLog.clear; propagate errors through Settings/validation and aggregate full-reset result.
- [ ] 3. Add real temporary model-file tests (valid, missing, zero/truncated, shards) and cancellation/deletion race tests; implement local validation and safe deletion.
- [ ] 4. Add JournalDraftStore round-trip/error/delete tests and capture draft lifecycle tests; implement atomic local persistence, resume/discard UI, and full-reset deletion.
- [ ] 5. Commit tests first and dispatch dedicated branch CI for RED; implement and run full GREEN CI. Review complete diff with a fresh reviewer; resolve significant findings; deliver reviewable branch/PR with evidence.

## Execution notes
- User's approval refers to the analysis and its recommended four-item order; implementation details above are agent choices.
- Local Swift is unavailable. CI is the executable verification gate; do not label unrun local tests passing.
