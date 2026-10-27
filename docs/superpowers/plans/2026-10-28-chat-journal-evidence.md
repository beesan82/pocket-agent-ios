# Chat Journal Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the exact journal text supplied to the most recent completed on-device chat answer, so a wrong hotel answer can be traced to retrieval or generation.

**Architecture:** `ChatSession.turnContext` returns both the existing instruction section and its effective journal excerpt. `ChatSession` keeps the excerpt only after a completed, saved local answer, tagged with that assistant turn's index. `ChatView` renders it in a disclosure below that turn. This diagnostic state is in memory only.

**Tech Stack:** Swift, SwiftUI, SwiftData, Swift Testing, GitHub Actions Xcode 27.

**Spec:** `docs/superpowers/specs/2026-10-28-chat-journal-evidence-design.md`

## Global Constraints

- Display the exact journal lines passed to model instructions, including the recent-journal fallback.
- Show no reference while generation is pending, stopped or failed, and do not persist it.
- Do not put journal content in `MeasurementLog` or send it externally.
- Preserve existing chat history and SwiftData schema.

## Review Focus

- A matching journal name in a transcript appears in the displayed excerpt when it appears in model instructions.
- A non-matching question displays the actual recent-journal fallback instead of claiming nothing was used.
- No journal data displays an explicit empty-reference message only after a completed local answer.
- A stopped or failed send never displays provisional evidence.
- A later user message does not display the previous answer's evidence under the wrong turn.

---

### Task 1: Capture effective journal evidence on completed local turns

**Files:**
- Modify: `App/PocketAgent/Chat/ChatSession.swift`
- Test: `App/PocketAgentTests/ChatSessionLocalTests.swift`

**Interfaces:**
- Produce: `ChatSession.lastJournalReference: JournalReference?`, where `JournalReference` has `assistantTurnIndex: Int` and `text: String?` (`nil` means no journal supplied).
- Change private `turnContext(for:limit:budget:)` to return a section plus the journal text extracted from that same section; Claude consumes only the section.

- [ ] **Step 1: Write failing tests** for a matched journal containing `台南ホテル`, recent fallback, empty journal, stopped send, and clearing when another message is sent. Assert the reference exists only after a saved local answer and its text equals the journal lines inside the runner's instructions.
- [ ] **Step 2: Verify RED** with a full iOS CI run at a test-only commit; expect the new assertions to fail because the state is absent.
- [ ] **Step 3: Implement** `JournalReference`, context capture and completion-only assignment. Extract fallback journal lines from the already rendered memory section, which flattens stored text so it cannot fake a heading.
- [ ] **Step 4: Verify GREEN** with a full iOS CI run; expect simulator tests and both builds to pass.
- [ ] **Step 5: Commit** the tested model behavior.

### Task 2: Show evidence in the chat

**Files:**
- Modify: `App/PocketAgent/Views/ChatView.swift`

**Interfaces:**
- Consume: `ChatSession.lastJournalReference` from Task 1.

- [ ] **Step 1: Add** a `DisclosureGroup("参照した日誌")` under the matching assistant turn. Show `text` or `参照した日誌はありません`; allow text selection. Do not render it for other turns.
- [ ] **Step 2: Verify** simulator and device builds with full iOS CI, then inspect the diff for privacy and turn-index behavior.
- [ ] **Step 3: Commit** the UI change and update the draft PR summary and limits.

## Device check after build

Ask `1日目のホテルは？` on the actual Qwen device and inspect `参照した日誌`: if `台南ホテル` is absent, improve retrieval; if present, test grounding and answer generation with that evidence.
