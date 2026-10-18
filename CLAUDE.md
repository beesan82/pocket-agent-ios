# Claude Code 開発ガイド — Pocket Agent (仮称)

このリポジトリでは `AGENT_REQUIREMENTS.md` を唯一の要件基準文書とする。作業を始める前に全文を読むこと。

## プロジェクトのゴール
SwiftUI + AgentRunKitによるiPhone完結型エージェントを構築する。Claude Messages APIとApple Foundation Modelsの切替をMVPで実現し、LINEへのテキスト共有は人間の明示承認と最終送信を必須とする。MLX対応はPhase 2。

## 絶対に守ること
- iOSの非公開API、他社アプリへのタップ注入、Claude CodeのOAuthトークン抜き出し・クライアント偽装を実装しない。
- Claude Teamログインのトークンが独自iOSアプリで使える前提にしない。公式APIキー／App Attest等で設計する。
- APIキーをコードやGit/CIログへ格納しない。Keychainを使う。
- LINE URLスキームで共有先選択画面を開くことと、送信完了を混同しない。
- 端末内推論を選んだときは、会話をクラウドへ無断送信しない。
- SDKの使用例を推測で書かず、採用版のソースとCIビルドで確認する。

## 開発順序
1. リポジトリを確認し、`docs/architecture.md` と Phase 0 チェックリストを作る。
2. Windows/Linuxで保守できるXcodeプロジェクト構成と、GitHub Actions macOS CIを用意。
3. AgentRunKit v6.1.0候補版を固定してiOSビルドを通す。
4. FakeLLMを作り、ツール・承認・停止・上限をテスト。
5. Claude Messages APIとApple Foundation Modelsを別Adapterで実装し、1往復ずつ実機検証。
6. チャットUI、Keychain、履歴、LINE共有フローを実装。
7. テストAT-01～AT-14を確認し、Codemagic署名＋TestFlightを接続。
8. Phase 2としてMLXの実機性能調査へ進む。

## 毎回の報告形式
- 対応した要件ID
- 変更ファイル
- 具体的な実装内容
- 実行したテストと結果
- 未確認事項／ブロッカー
- 次の推奨作業

## 最初の依頼
`AGENT_REQUIREMENTS.md` を読んで、Phase 0の実装計画とディレクトリ構成案を作成してから、クラウドmacOS CIでビルドできる最小SwiftUIプロジェクトを構築せよ。未検証の機能を「完成」と報告しないこと。
