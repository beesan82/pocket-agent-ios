# Pocket Agent（仮称）

iPhone 完結型マルチモデル AI エージェント。要件は [AGENT_REQUIREMENTS.md](AGENT_REQUIREMENTS.md)、設計は [docs/architecture.md](docs/architecture.md)。

## 現在の状態: Phase 0（技術スパイク）

| 項目 | 状態 |
|---|---|
| XcodeGen プロジェクト / 最小 SwiftUI アプリ | 実装済み・**CI 未実行** |
| AgentRunKit 6.1.0（exact）のリンク | 実装済み・**CI 未実行** |
| LINE 共有 URL 生成 + ユニットテスト | 実装済み・**CI 未実行**（UI 未接続） |
| GitHub Actions macOS CI | 実装済み・**未実行** |
| チャット / Claude / Apple ローカル / Keychain / 履歴 / 承認 | 未実装 |
| Codemagic / TestFlight | 未実装 |

進捗の詳細は [docs/phase0-checklist.md](docs/phase0-checklist.md)。

**このアプリは LINE を自動操作しません。** 「LINEで共有」は LINE 公式の送信先選択画面を開くだけで、送信はユーザーが LINE 上で行います。

## Windows からの開発手順

1. Git for Windows をインストールし、このフォルダを GitHub の private リポジトリへ push する。
2. GitHub の Actions タブで `iOS CI` の結果を確認する（macOS runner 上で XcodeGen → ビルド → テスト）。
3. 成功したら成果物 `ci-evidence` の `Package.resolved` を確認する。

`.xcodeproj` はコミットしない。プロジェクト構成の変更は `project.yml` を編集する。

## 秘密情報

- API キー・署名証明書はリポジトリ、チャット、CI ログに置かない。API キーはアプリ内でのみ入力し、Keychain に保存する（Phase 1 で実装予定）。
- CI の `ci/secret-scan.sh` が鍵らしき文字列を検出したらビルドを失敗させる。

## ローカルでのテスト（任意）

Swift ツールチェーンがある環境なら、Core パッケージ単体はテストできる見込み（Windows/Linux での動作は未検証）:

```bash
swift test --package-path Packages/PocketAgentCore
```
