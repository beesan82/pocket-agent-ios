# Claude Code 開発ガイド — Pocket Agent (仮称)

このリポジトリでは `AGENT_REQUIREMENTS.md` を唯一の要件基準文書とする。作業を始める前に全文を読むこと。
作業の進め方（CI、TDD、失敗するコミットの扱い、共有ブランチでの commit と push）は `AGENTS.md` に従うこと。

## プロジェクトのゴール
SwiftUI + AgentRunKitによるiPhone完結型エージェントを構築する。Claude Messages APIとApple Foundation Modelsの切替をMVPで実現し、LINEへのテキスト共有は人間の明示承認と最終送信を必須とする。MLX対応はPhase 2。

## 絶対に守ること
- iOSの非公開API、他社アプリへのタップ注入、Claude CodeのOAuthトークン抜き出し・クライアント偽装を実装しない。
- Claude Teamログインのトークンが独自iOSアプリで使える前提にしない。公式APIキー／App Attest等で設計する。
- APIキーをコードやGit/CIログへ格納しない。Keychainを使う。
- LINE URLスキームで共有先選択画面を開くことと、送信完了を混同しない。
- 端末内推論を選んだときは、会話をクラウドへ無断送信しない。
- SDKの使用例を推測で書かず、採用版のソースとCIビルドで確認する。

## これまでの経緯と現在地
Phase 0 の開発順序（CI、AgentRunKit 固定、FakeLLM、Claude と Apple の Adapter、チャット・Keychain・履歴・LINE 共有、Codemagic と TestFlight）は完了済み。
Phase 2 の MLX（端末内日誌）も実装済みで、その後に会議モード、二言語会議、端末内モデルの Foundation Models 化、日誌のチャット統合、記録タブ統合を進めた。
最新の決定は `docs/decisions.md`、実装済みと実機未検証の一覧は `docs/phase0-checklist.md` を見ること。

## 毎回の報告形式
- 対応した要件ID
- 変更ファイル
- 具体的な実装内容
- 実行したテストと結果
- 未確認事項／ブロッカー
- 次の推奨作業

## 作業の始め方
1. `AGENT_REQUIREMENTS.md`、`AGENTS.md`、`docs/architecture.md`、`docs/decisions.md` の最新の ADR、`docs/phase0-checklist.md` を読む。
2. `git log --oneline -15` と `gh run list --workflow ios-ci.yml --limit 5` で現状を確かめる。
3. 未検証の機能を「完成」と報告しないこと。
