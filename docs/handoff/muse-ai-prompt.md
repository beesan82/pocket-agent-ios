# muse.ai 引き継ぎプロンプト（Pocket Agent）

以下を muse.ai の最初のメッセージとして貼り付ける。作業の決まりはリポジトリの `AGENTS.md` にあるので、このプロンプトは入口と現在地だけを伝える。

---

あなたは iOS アプリ「Pocket Agent（仮称）」の開発を、別の開発環境（Claude Code デスクトップ版）から引き継ぎます。返答と報告は日本語で書いてください。

## リポジトリ
- GitHub: https://github.com/beesan82/pocket-agent-ios（public）。既定ブランチ `main`。
- 作業を始める前に次を全文読むこと。
  1. `AGENT_REQUIREMENTS.md`（唯一の要件基準）
  2. `AGENTS.md`（作業の決まり: CI の回し方、TDD、失敗するコミットを main に push しない手順、共有ブランチでの commit と push、秘密情報、配信）
  3. `CLAUDE.md`（絶対に守ること、毎回の報告形式）
  4. `README.md`（現在の状態の概要）と `docs/architecture.md`（レイヤー構成とディレクトリ図）
  5. `docs/decisions.md`（ADR-001〜043。最新の決定はここが正）
  6. `docs/phase0-checklist.md`（実装済み・実機未検証の一覧）と `docs/test-plan.md`（AT-01〜AT-15）

## 特に守ること（詳細は AGENTS.md）
- ローカルに Mac も Swift もない前提。Swift のビルドとテストはすべて GitHub Actions で行い、CI を通していない変更は「未検証」と報告する。
- 失敗するテストを先に書く。その失敗の確認は一時ブランチで行い、失敗するコミットを `main` に push しない。
- 通るコミットは `main` へ直接 push してよい。push の後は `gh` で CI の成功を確かめてから「完了」と報告する。
- 他の作業者も同じ `main` に push する。自分が変えたファイルだけを stage し、push 前に `git fetch` して必要なら rebase する。
- 秘密情報（API キー、.p8、証明書）を求めない、置かない。TestFlight への配信は人が Codemagic から手動で起動する。
- 決定を変えたら `docs/decisions.md` に ADR を追記する。次の番号は ADR-044。

## 現在の状態（2026-11-03 時点）
- 最新の main は PR #4「Improve on-device journal recall and show selected evidence」のマージ（`3bbb1eb`）と、その後の文書整備（AGENTS.md の追加、README・CLAUDE.md・architecture.md の更新）。
- 直近の変更: チャットが毎ターン日誌を語と日付で引く（ADR-040）。その再現率を、漢字の部分語・Apple 向けの文脈予算の拡大・`search_notes` の OR フォールバック・プロンプト変更で上げた（ADR-043）。端末内モデルの回答の下に、渡した日誌の節を「根拠」として表示する。ダウンロードモデル候補に Qwen3-4B-Instruct-2507 を追加（ADR-042）。
- 実機未検証の主な項目:
  - Apple Intelligence に以前「該当する日誌がありません」と返された質問（例: 「宿泊先はどこだった？」）をもう一度して、根拠表示に該当日誌が出るか。
  - Apple の文脈（日誌検索 1200 字、メモ節 2000 字、履歴 1500 字、指示文）が約 4096 トークンに収まるか。
  - そのほか `docs/phase0-checklist.md` の「実機で未検証」の各項目。

## 最初にやること
1. 上の文書を読み、`git log --oneline -15` と `gh run list --workflow ios-ci.yml --limit 5` で現状を確かめる。
2. `gh` で push と Actions の実行ができるか（認証と権限）を確かめ、できなければユーザーに伝える。
3. 読んだ内容の要約と、文書と実態のずれがあればその一覧を報告し、続きの作業はユーザーの指示を待つ。
