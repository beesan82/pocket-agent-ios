# Claude Code 開発ガイド — ポケット執事（開発名 Pocket Agent）

このリポジトリでは `AGENT_REQUIREMENTS.md` を唯一の要件基準文書とする。作業を始める前に全文を読むこと。
作業の進め方（CI、TDD、失敗するコミットの扱い、共有ブランチでの commit と push）は `AGENTS.md` に従うこと。

## プロジェクトのゴール
詳細は `AGENT_REQUIREMENTS.md` 第0章（版 1.1、ADR-053）。作業の採否はここで判断する。
- **存在理由は金庫**: 機微情報（会話・メモ・日誌・会議の文字起こし）を iPhone の中に閉じ込める（2026-11-03 再定義）。
- **改善の舵は文字起こし**: 開発資源は文字起こしの性能アップに集中する。文字起こしにも金庫にも効かない機能は、製品化の形が決まるまで足さない。
- **エージェントは残す**: 端末内オフラインエージェントは「金庫の中で働く執事」として維持する。捨てて金庫に一本化しない。
- **測定の制約**: 実機確認は所有者 1 人に直列で依存する。実機確認が要る項目は最小の束にまとめ、新規の宿題を際限なく積まない。
- 土台は SwiftUI + AgentRunKit の iPhone 完結型アプリ。Claude Messages API と端末内モデル（Apple Foundation Models、ダウンロードモデル）を切り替えられ、LINE へのテキスト共有は人間の明示承認と最終送信を必須とする。

## 絶対に守ること
- iOSの非公開API、他社アプリへのタップ注入、Claude CodeのOAuthトークン抜き出し・クライアント偽装を実装しない。
- Claude Teamログインのトークンが独自iOSアプリで使える前提にしない。公式APIキー／App Attest等で設計する。
- APIキーをコードやGit/CIログへ格納しない。Keychainを使う。
- LINE URLスキームで共有先選択画面を開くことと、送信完了を混同しない。
- 端末内推論を選んだときは、会話をクラウドへ無断送信しない。
- 測定ログ・デバッグ出力に、話した内容・書いた内容・生成した本文を入れない（件数・字数・所要時間だけ。ADR-026、ADR-053）。
- 端末外へ出る経路を増やす変更は、先に ADR に書いて所有者の判断を得る。
- SDKの使用例を推測で書かず、採用版のソースとCIビルドで確認する。

## これまでの経緯と現在地
Phase 0 の開発順序（CI、AgentRunKit 固定、FakeLLM、Claude と Apple の Adapter、チャット・Keychain・履歴・LINE 共有、Codemagic と TestFlight）は実装と CI まで完了済み（完了条件のうち実機での 2 モデル経路の確認は未チェックのまま。`docs/phase0-checklist.md`）。
Phase 2 の MLX（端末内日誌）も実装済みで、その後に会議モード、二言語会議、端末内モデルの Foundation Models 化、日誌のチャット統合、記録タブ統合を進めた。
2026-11-03 に存在理由を金庫へ再定義し、舵を文字起こしへ切った。要求と実装の乖離は `docs/gap-analysis-2026-11-16.md` にまとめてある。
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
