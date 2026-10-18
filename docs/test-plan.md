# Test Plan

| ID | 種別 | 自動化手段 | 証跡 | 状態 |
|---|---|---|---|---|
| AT-01 Claude接続 | 実機 + Unit(FakeLLM) | 無効キー時のエラー表示は Unit、実通信は実機 | 実機記録 | 未着手 |
| AT-02 Appleローカル | 実機 | 機内モードで生成 | 実機記録 | 未着手 |
| AT-03 非対応端末 | Unit + 実機 | availability をモック | CI / 実機 | 未着手 |
| AT-04 モデル切替 | Unit + 実機 | Adapter 差し替えテスト | CI / 実機 | 未着手 |
| AT-05 ツール承認 | Unit | `AgentRunnerTests.deniedSideEffectToolIsNeverExecuted` ほか | CI | **Unit 合格（run 39098564327）**。実 LINE ツールは未接続 |
| AT-06 LINE共有 | Unit + 実機 | `LineShareURLBuilderTests` | CI / 実機 | **Unit は CI で合格（cc13b32）、実機未確認** |
| AT-07 誤送信防止 | Unit + 目視 | 状態が「共有画面を開いた」止まり | CI / 実機 | 未着手 |
| AT-08 キャンセル | Unit | `cancelWhileAwaitingApprovalSkipsTool` | CI | **Unit 合格（run 39098564327）**。UI の停止ボタンは未実装 |
| AT-09 上限 | Unit | `runawayLoopStopsAtStepLimit` | CI | **Unit 合格（run 39098564327）** |
| AT-10 履歴削除 | Unit | Repository テスト | CI | 未着手 |
| AT-11 セキュリティ | CI | `ci/secret-scan.sh`（最小版） | CI ログ | **最小版が CI で合格（cc13b32）** |
| AT-12 CI | CI | `.github/workflows/ios-ci.yml` | Actions ログ | **合格（cc13b32, 2026-10-18）** |
| AT-13 配布 | Codemagic | — | TestFlight | 未着手 |
| AT-14 ローカル通信 | Unit + 実機 | ローカル選択時に Claude Adapter が生成されないこと | CI / 実機 | 未着手 |
| AT-15 MLX | 実機 | Phase 2 | — | 対象外 |

## 実機記録テンプレート
機種 / iOS / RAM / モデル名・量子化 / 操作 / 所要時間 / 結果 / 備考
