# Pocket Agent（仮称）

iPhone 完結型マルチモデル AI エージェント。要件は [AGENT_REQUIREMENTS.md](AGENT_REQUIREMENTS.md)、設計は [docs/architecture.md](docs/architecture.md)、決定の記録は [docs/decisions.md](docs/decisions.md)。
作業の決まり（CI、TDD、push の扱い）は [AGENTS.md](AGENTS.md)。

## 現在の状態

Phase 0（技術スパイク）と Phase 1（チャット・メモ・LINE 共有）は完了し、Phase 2 以降の機能を追加している。
多くの機能は CI の自動テストに合格しているが、実機では未確認のものが多い。詳細は [docs/phase0-checklist.md](docs/phase0-checklist.md)。

| 機能 | 状態 |
|---|---|
| チャット（Claude / Apple Foundation Models / ダウンロードした MLX モデル） | CI 合格。端末内モデルは Foundation Models 経由（ADR-037） |
| メモツール（保存・編集・一覧・検索・削除）と承認シート | CI 合格。書き込みと削除は毎回または会話単位で承認 |
| 日誌（文字・音声）と会議（文字起こし・要点・二言語）を「記録」タブに統合 | CI 合格。実機は一部のみ確認 |
| チャットからの日誌参照（毎ターン日付と語で検索、根拠表示） | CI 合格。実機未検証（ADR-040、ADR-043） |
| Keychain での API キー保存、会話履歴（SwiftData） | CI 合格 |
| LINE への共有（共有先選択画面を開くだけ） | CI 合格 |
| GitHub Actions の iOS CI | 稼働中（パッケージテスト、ビルド、シミュレータ単体テスト） |
| Codemagic から TestFlight への配信 | 稼働中（手動起動） |

**このアプリは LINE を自動操作しません。** 「LINEで共有」は LINE 公式の送信先選択画面を開くだけで、送信はユーザーが LINE 上で行います。

## 開発の流れ（Windows から）

1. コードを変更して push する。Mac は不要で、Swift のビルドとテストは GitHub Actions の `iOS CI` が行う。
2. GitHub の Actions タブか `gh run list --workflow ios-ci.yml` で結果を確かめる。
3. 実機で試すときは、Codemagic で「iOS TestFlight」ワークフローを `main` に対して手動で起動し、iPhone の TestFlight アプリから入れる。初回設定は [docs/testflight-setup.md](docs/testflight-setup.md)。

`.xcodeproj` はコミットしない。プロジェクト構成の変更は `project.yml` を編集する。

## 秘密情報

- API キー・署名証明書はリポジトリ、チャット、CI ログに置かない。Claude の API キーはアプリ内でのみ入力し、Keychain に保存する。
- 署名と App Store Connect のキーは Codemagic と App Store Connect の画面にだけ登録する。
- CI の `ci/secret-scan.sh` が鍵らしき文字列を検出したらビルドを失敗させる。

## ローカルでのテスト（任意）

Mac で Swift ツールチェーンがあれば、パッケージ単体のテストを実行できる。

```bash
swift test --package-path Packages/PocketAgentCore
```

```bash
swift test --package-path Packages/PocketAgentRuntime
```
