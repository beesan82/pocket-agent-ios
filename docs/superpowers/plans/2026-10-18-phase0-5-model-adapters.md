# Phase 0-5 Model Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude / Apple ローカルを設定で切り替え、`AgentRunner` で 1 往復できる最小経路を作る。

**Architecture:** 選択→可否判定→クライアント生成の判断は Core のジェネリック `ModelBackendResolver` に置き、SDK 型は Runtime（Claude）と App（Foundation Models・Keychain・UI）に閉じ込める。SDK クライアントは包まずに `any LLMClient` として渡す。

**Tech Stack:** Swift 6 / SwiftUI / AgentRunKit 6.1.0 / FoundationModels / Security / swift-testing

**Spec:** `docs/superpowers/specs/2026-10-18-phase0-5-model-adapters-design.md`

## Global Constraints
- Core は Foundation のみ。AgentRunKit を import しない。
- APIキーをログ・エラー文言・UserDefaults・テストフィクスチャ（`sk-ant-` 形式）に出さない。テスト用キーは `test-key` のような secret-scan に掛からない文字列。
- Apple ローカル選択時はキーを読まず Claude クライアントを生成しない（AT-14）。非対応時は理由を返して止める（AT-03）。
- SDK クライアントを独自型で包まない（ContentOnlyTerminatingClient 判定のため）。
- Apple ローカルには tools を渡さない（承認ゲート迂回のため）。
- ローカルで Swift は動かない。検証はすべて CI（`gh run watch`）。

## Review Focus
1. キーが前後空白付き／空白のみ → trim、空白のみは `.missingAPIKey`（Task 1, 2 のテスト）。
2. Apple が使えない状態で Claude キーが保存済み → それでも `.unavailable`、キーは読まれない（Task 1）。
3. 401 応答の本文にキー断片が含まれても文言に出ない（Task 2）。
4. 実行中にモデルを切り替え → 次回送信時に再解決（UI は送信毎に resolve する。Task 4）。
5. Keychain 保存の上書き（2回保存）→ 後の値が読める（Task 3）。

---

### Task 1: Core ポートと ModelBackendResolver
**Files:** Create `Packages/PocketAgentCore/Sources/PocketAgentCore/ModelSelection.swift`; Test `Packages/PocketAgentCore/Tests/PocketAgentCoreTests/ModelBackendResolverTests.swift`

**Produces:**
- `enum ModelChoice: String, Sendable, CaseIterable, Codable { case claude, appleLocal }` + `displayName`
- `enum ModelUnavailableReason: Sendable, Equatable { missingAPIKey, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unsupportedOS, unknown(String) }` + `userMessage: String`
- `protocol CredentialStore: Sendable { func readAPIKey() throws -> String?; func saveAPIKey(_:) throws; func deleteAPIKey() throws }`
- `protocol ModelAvailabilityChecking: Sendable { func appleLocalUnavailableReason() -> ModelUnavailableReason? }`
- `enum ModelResolutionError: Error, Equatable { unavailable(ModelUnavailableReason), credentialReadFailed, clientCreationFailed }`
- `struct ModelBackendResolver<Backend>` with `init(credentials:availability:makeClaude: (String) throws -> Backend, makeAppleLocal: () throws -> Backend)` and `func resolve(_ choice: ModelChoice) -> Result<Backend, ModelResolutionError>`

- [ ] Tests: `appleLocalNeverReadsKeyOrBuildsClaude` (spy store counts reads = 0, claude factory count = 0), `appleLocalUnavailableDoesNotFallBackToClaude` (key saved, availability `.deviceNotEligible` → `.failure(.unavailable(.deviceNotEligible))`, claude count 0), `claudeWithoutKeyIsMissingAPIKey` (nil and "  " → `.missingAPIKey`), `claudeTrimsKey` ("  k \n" → factory receives "k"), `claudeNeverChecksAppleAvailability`, `claudeFactoryThrowIsClientCreationFailed`, `keychainReadErrorIsCredentialReadFailed`, every reason has non-empty `userMessage`.
- [ ] Implement; push; CI Core step green.

### Task 2: ClaudeAdapter + LLMErrorDescriber (Runtime)
**Files:** Create `Packages/PocketAgentRuntime/Sources/PocketAgentRuntime/ClaudeAdapter.swift`, `LLMErrorDescriber.swift`; Test `Tests/PocketAgentRuntimeTests/ClaudeAdapterTests.swift`, `StubURLProtocol.swift`

**Produces:**
- `enum ClaudeAdapter { static let defaultModel = "claude-sonnet-5-5"; static let defaultMaxTokens = 1024; static func makeClient(apiKey: String, model: String, maxTokens: Int = defaultMaxTokens, session: URLSession = .shared) throws -> AnthropicClient }` — throws `ClaudeAdapter.ConfigurationError.emptyAPIKey / .emptyModel`; `retryPolicy` 既定。
- `enum LLMErrorDescriber { static func userMessage(for error: any Error) -> String }` — 401/403 → 「APIキーが無効か、権限がありません。設定画面でキーを確認してください。」, 429/rateLimited → 混雑, networkError → 通信不可, providerError/other → 汎用。本文は出さない。

- [ ] Tests (stub `URLSession` via `URLProtocol`, serialized suite): `textReplyCompletesRun` (200 `{"content":[{"type":"text","text":"こんにちは"}]}` → `AgentRunner` outcome `.completed("こんにちは")`, request host `api.anthropic.com`, path ends `/messages`, `x-api-key == "test-key"`, body `model == "claude-sonnet-5-5"`), `unauthorizedMapsToKeyMessageWithoutBody` (401 body containing "test-key-secret-echo" → thrown error; message contains "APIキー" and not "secret-echo"), `emptyKeyThrows`.
- [ ] Implement; CI Runtime step green.

### Task 3: App adapters — Keychain / Apple availability / factory
**Files:** Create `App/PocketAgent/Adapters/KeychainCredentialStore.swift`, `AppleLocalAvailability.swift`, `LLMClientFactory.swift`, `App/PocketAgent/Settings/ModelSettings.swift`; Tests `App/PocketAgentTests/AppleLocalAvailabilityTests.swift`, `KeychainCredentialStoreTests.swift`, `LLMClientFactoryTests.swift`

**Produces:**
- `struct KeychainCredentialStore: CredentialStore { init(service: String = "com.example.pocketagent.anthropic", account: String = "api-key") }`, `struct KeychainError: Error { let status: OSStatus }`.
- `struct AppleLocalAvailability: ModelAvailabilityChecking`; `static func reason(for: SystemLanguageModel.Availability) -> ModelUnavailableReason?`.
- `@MainActor @Observable final class ModelSettings { var choice: ModelChoice; var claudeModel: String }` (UserDefaults, injectable).
- `enum LLMClientFactory { static func resolver(credentials:availability:claudeModel:) -> ModelBackendResolver<any LLMClient> }` — Apple: `FoundationModelsClient<EmptyContext>(context: EmptyContext())`, Claude: `ClaudeAdapter.makeClient`.

- [ ] Tests: availability mapping for each case; factory with `.appleLocal` + spy store → no reads and resolved client `providerIdentifier == .foundationModels` (when available stub) ; `.claude` → `.anthropic`; Keychain save/read/overwrite/delete round trip (skip with message if status -34018 under unsigned simulator).

### Task 4: UI — SettingsView / RoundTripView
**Files:** Create `App/PocketAgent/Views/SettingsView.swift`, `RoundTripView.swift`; Modify `ContentView.swift`, `PocketAgentApp.swift`.
- SettingsView: SecureField + 保存/削除、保存済みは「保存済み」表示のみ（値は表示しない）、Picker（ModelChoice）、Apple 可否と理由、Claude モデル ID。
- RoundTripView: 送信時に resolve → `AgentRunner<EmptyContext>(client:tools: [])` で run、結果・`LLMErrorDescriber` 文言・不可理由を表示、停止ボタン（Task cancel → `.cancelled`）。
- [ ] CI build green（UI は実機未検証と明記）。

### Task 5: Docs + CI 確認
- [ ] `docs/phase0-checklist.md`, `docs/test-plan.md`, `docs/decisions.md`（ADR-008 クライアント非ラップ, ADR-009 Apple ローカルに tools を渡さない, ADR-010 Keychain 属性）を run ID 付きで更新し push。
