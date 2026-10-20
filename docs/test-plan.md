# Test Plan

| ID | 種別 | 自動化手段 | 証跡 | 状態 |
|---|---|---|---|---|
| AT-01 Claude接続 | 実機 + Unit | `ClaudeAdapterTests`（URLProtocol スタブで実 `AnthropicClient`: 1往復完了・401 で「APIキー」文言、本文/キーを表示しない） | CI / 実機 | **Unit 合格（run 39101123691）**。実通信は実機未検証 |
| AT-02 Appleローカル | 実機 | 機内モードで生成（日誌の MLX 経路も同様） | 実機記録 | 未検証（機内モード）。音声入力（SpeechTranscriber ja-JP）は iPhone 15 で利用可能と実機確認済み（2026-10-19、ビルド 5） |
| AT-03 非対応端末 | Unit + 実機 | `ModelBackendResolverTests.appleLocalUnavailableDoesNotFallBackToClaude`、`AppleLocalAvailabilityTests`、`LLMClientFactoryTests.unavailableAppleLocalNeverFallsBackToClaude`、`MLXRuntimeTests.simulatorReasonWinsOnSimulator` | CI / 実機 | **Unit 合格（run 39284990942）**。**実機確認済み（2026-10-19、iPhone 15、ビルド 4）**: Apple ローカルの行が無効で「この端末はApple Intelligenceに対応していません」を表示、クラッシュなし |
| AT-04 モデル切替 | Unit + 実機 | `LLMClientFactoryTests.switchingChoiceSwitchesProvider`（Claude→Apple→Claude） | CI / 実機 | **Unit 合格（run 39101123691）**。実機未検証 |
| AT-05 ツール承認 | Unit | `AgentRunnerTests.deniedSideEffectToolIsNeverExecuted` ほか、Apple 経路は `ApprovalGatedToolTests`、メモ: `NoteToolsTests.saveRequiresApprovalAndStores` / `deniedSaveStoresNothing` / `deleteAsksEveryTimeOnBothPaths` / `injectedDeleteIsBlockedByDenial`、会話単位許可: `ConversationApprovalsTests.sessionApprovalSpansRuns` / `deleteAlwaysAsksEvenAfterSessionApproval` / `sameApprovalsCoverGatePath`、`ChatSessionTests.sessionApprovalSurvivesModelSwitch` / `deleteApprovalShowsNoteText` | CI | **Unit 合格（run 39114462235）**。承認シートの実機操作・連続表示は未検証 |
| AT-06 LINE共有 | Unit + 実機 | `LineShareURLBuilderTests`、`ShareFlowTests.urlEncodesText` / `failedOpenIsReported` | CI / 実機 | **Unit 合格（run 39114462235）**。実機の LINE 共有画面は未確認 |
| AT-07 誤送信防止 | Unit + 目視 | `ShareFlowTests.openedMessageNeverClaimsSent` / `confirmOnlyWhileConfirming` / `cancelReturnsToCancelled`（「送信済み」状態は存在しない、ADR-016） | CI / 実機 | **Unit 合格（run 39114462235）**。確認ダイアログの表示・文言は実機未検証 |
| AT-08 キャンセル | Unit | `AgentRunnerTests` / `ApprovalGatedToolTests` の `cancelWhileAwaitingApprovalSkipsTool`、`NoteToolsTests.cancelWhileAwaitingApprovalSavesNothing`、`ChatSessionTests.stopMarksCancelledAndSavesNoAssistantTurn` / `cancellingDeniesOnce` | CI | **Unit 合格（run 39114462235）**。チャット画面の停止ボタン、承認シート表示中の停止、FoundationModels のキャンセル伝播は実機未検証 |
| AT-09 上限 | Unit | `runawayLoopStopsAtStepLimit` | CI | **Unit 合格（run 39098564327）** |
| AT-10 履歴削除 | Unit | `PersistenceTests.deletingConversationRemovesTurns` / `eraseAllRemovesEverything`、`JournalPersistenceTests.eraseAllRemovesJournal` / `eraseAllRemovesLeftoverNoteRecords`、`MeasurementLogTests.clearRemovesPersistedFileContent`（in-memory SwiftData） | CI | **Unit 合格（run 39284990942）**。UI 操作（スワイプ削除・全データ削除）、移行後の実データでの全削除は実機未検証 |
| AT-11 セキュリティ | CI + Unit | `ci/secret-scan.sh`（最小版）、`KeychainCredentialStoreTests`、`ModelSettingsTests.nothingKeyLikeIsWrittenToDefaults` | CI ログ | **合格（run 39101123691）** |
| AT-12 CI | CI | `.github/workflows/ios-ci.yml` | Actions ログ | **合格（cc13b32, 2026-10-18）** |
| AT-13 配布 | Codemagic | — | TestFlight | 未着手 |
| AT-14 ローカル通信 | Unit + 実機 | `ModelBackendResolverTests.appleLocalNeverReadsKeyOrBuildsClaude`、`LLMClientFactoryTests.appleLocalBuildsFoundationModelsClientWithoutTouchingKey`（キー読み出し 0 回・`AnthropicClient` 非生成）、日誌: `JournalPersistenceTests.noteToolsSeeOnlyNoteToolEntries`（Claude のノートツールは `.noteTool` のみ参照、ADR-021）、読み込みはローカルディレクトリのみ（ADR-023） | CI / 実機 | **Unit 合格（run 39284990942）**。Apple 経路のチャット（`ChatSessionTests.appleLocalSecondTurnSendsOneFoldedPrompt`）も会話をクラウドへ送らない構成を維持。機内モードでの実機確認は未検証 |
| AT-15 MLX | Unit + 実機 | `MLXModelStoreTests`（`downloadRefusedWhenDiskTooSmall` / `downloadProgressAndCompletion` / `cancelLeavesNotDownloaded` / `downloadFailureShowsFixedText`）、`SDKLinkCheckTests.mlxClientIsLinked`、日誌の要約・質問・保存の各テスト（Core 68 / Runtime 64 / App 112） | CI / 実機 | **Unit 合格（run 39284990942）**。実機: Qwen2.5-1.5B の要約は短文 3.0 秒 / 中文 6.0 秒 / 長文 12.0 秒、メモリ警告なし（2026-10-19、ビルド 5、`docs/phase2-mlx-eval.md`）。日誌画面の通し操作・質問・機内モードは未検証（`docs/phase0-checklist.md` Phase 2 節） |

## 実機記録テンプレート
機種 / iOS / RAM / モデル名・量子化 / 操作 / 所要時間 / 結果 / 備考
