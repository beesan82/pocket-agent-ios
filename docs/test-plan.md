# Test Plan

| ID | 種別 | 自動化手段 | 証跡 | 状態 |
|---|---|---|---|---|
| AT-01 Claude接続 | 実機 + Unit | `ClaudeAdapterTests`（URLProtocol スタブで実 `AnthropicClient`: 1往復完了・401 で「APIキー」文言、本文/キーを表示しない） | CI / 実機 | **Unit 合格（run 39101123691）**。実通信は実機未検証 |
| AT-02 Appleローカル | 実機 | 機内モードで生成 | 実機記録 | 未着手 |
| AT-03 非対応端末 | Unit + 実機 | `ModelBackendResolverTests.appleLocalUnavailableDoesNotFallBackToClaude`、`AppleLocalAvailabilityTests`、`LLMClientFactoryTests.unavailableAppleLocalNeverFallsBackToClaude` | CI / 実機 | **Unit 合格（run 39101123691）**。実機未検証 |
| AT-04 モデル切替 | Unit + 実機 | `LLMClientFactoryTests.switchingChoiceSwitchesProvider`（Claude→Apple→Claude） | CI / 実機 | **Unit 合格（run 39101123691）**。実機未検証 |
| AT-05 ツール承認 | Unit | `AgentRunnerTests.deniedSideEffectToolIsNeverExecuted` ほか | CI | **Unit 合格（run 39098564327）**。実 LINE ツールは未接続 |
| AT-06 LINE共有 | Unit + 実機 | `LineShareURLBuilderTests` | CI / 実機 | **Unit は CI で合格（cc13b32）、実機未確認** |
| AT-07 誤送信防止 | Unit + 目視 | 状態が「共有画面を開いた」止まり | CI / 実機 | 未着手 |
| AT-08 キャンセル | Unit | `cancelWhileAwaitingApprovalSkipsTool` | CI | **Unit 合格（run 39098564327）**。UI の停止ボタンは未実装 |
| AT-09 上限 | Unit | `runawayLoopStopsAtStepLimit` | CI | **Unit 合格（run 39098564327）** |
| AT-10 履歴削除 | Unit | Repository テスト | CI | 未着手 |
| AT-11 セキュリティ | CI + Unit | `ci/secret-scan.sh`（最小版）、`KeychainCredentialStoreTests`、`ModelSettingsTests.nothingKeyLikeIsWrittenToDefaults` | CI ログ | **合格（run 39101123691）** |
| AT-12 CI | CI | `.github/workflows/ios-ci.yml` | Actions ログ | **合格（cc13b32, 2026-10-18）** |
| AT-13 配布 | Codemagic | — | TestFlight | 未着手 |
| AT-14 ローカル通信 | Unit + 実機 | `ModelBackendResolverTests.appleLocalNeverReadsKeyOrBuildsClaude`、`LLMClientFactoryTests.appleLocalBuildsFoundationModelsClientWithoutTouchingKey`（キー読み出し 0 回・`AnthropicClient` 非生成） | CI / 実機 | **Unit 合格（run 39101123691）**。機内モードでの実機確認は未検証 |
| AT-15 MLX | 実機 | Phase 2 | — | 対象外 |

## 実機記録テンプレート
機種 / iOS / RAM / モデル名・量子化 / 操作 / 所要時間 / 結果 / 備考
