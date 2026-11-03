# AGENTS.md — Pocket Agent の作業の決まり

AI エージェント（Claude Code、muse.ai など）と人が、このリポジトリで作業するときの決まり。
要件は `AGENT_REQUIREMENTS.md`、守るべき制約と報告形式は `CLAUDE.md`、決定の記録は `docs/decisions.md` にある。
この文書は「どう作業するか」だけを書く。

## 言語
- 返答・報告・ADR・手順書は日本語で書く。コード内のコメントとコミットメッセージは英語でよい。

## 開発環境の前提
- 開発 PC は Windows で、Mac も Swift ツールチェーンもない。Swift のビルドとテストはすべて GitHub Actions で行う。
- CI を通していない変更は「未検証」と報告する。実機（iPhone 15 など）での確認は人が行い、結果を `docs/phase0-checklist.md` に記録する。
- `.xcodeproj` はコミットしない。プロジェクト構成は `project.yml`（XcodeGen）を編集する。

## CI（`.github/workflows/ios-ci.yml`、ランナー `xcode-27`）
- `main` への push と pull request で自動実行する。`docs/**`、`*.md`、`codemagic.yaml`、`tools/**` だけの変更では走らない。
- 流れ: 秘密情報スキャン → Core と Runtime の `swift test` → XcodeGen 生成 → パッケージ解決と版ずれ検査 → シミュレータ・実機向けビルド → シミュレータでのアプリ単体テスト。全体で約 15 分。
- パッケージのテストだけを回す:

  ```bash
  gh workflow run ios-ci.yml --ref <branch> -f packages_only=true
  ```

- 結果は `gh run list --workflow ios-ci.yml --branch <branch>` と `gh run view <id> --log` で読む。
- 同じブランチへ push すると、そのブランチで進行中の実行は取り消される（concurrency group）。結果を待っている実行があるときは push しない。
- 依存の版は `App/Package.resolved` に固定してある。解決結果がずれると CI が失敗する。依存を変えたら `App/Package.resolved` も更新する。

## TDD と失敗するコミットの扱い
1. 失敗するテストを先に書き、CI で失敗を確かめてから実装する。
2. **失敗する（RED）コミットを `main` に push しない。** `main` の失敗はリポジトリ所有者に通知メールが飛ぶ。
3. 失敗の確認は一時ブランチで行う。
   - 共有の作業ツリーでブランチを切り替えず、別の worktree で `main` から一時ブランチを作る。
   - その一時ブランチだけで、ワークフローの 2 つの `swift test` ステップに `continue-on-error: true` を足す。
   - push して `gh workflow run ios-ci.yml --ref <一時ブランチ> -f packages_only=true` を実行し、`gh run view <id> --log` から失敗を読む。
   - 終わったら一時ブランチをローカルとリモートの両方から消す。
4. 通る（GREEN）コミットは `main` へ直接 push してよい。大きめの変更はブランチと pull request にしてもよい。
5. push の後は `gh` で CI の成功を確かめてから「完了」と報告する。

## 複数の作業者で同じ main を使う
- 他のエージェントや人が同じ作業ツリーと `main` に並行して push する。
- `git add -A` や `git commit -a` は使わない。自分が変えたファイルだけを明示して stage する。
- 自分が作っていない未追跡ファイルや変更には触らない。
- push の前に `git fetch` し、`HEAD..origin/main` に新しいコミットがあれば自分のコミットを rebase してから push する。

## 決定と記録
- 決定を変えたら `docs/decisions.md` に ADR を追記する。番号は最後の ADR の次（重複がないか追記前に確かめる）。
- 実機での確認が要る変更は、`docs/verification/` に手順を書き、`docs/phase0-checklist.md` の「実機で未検証」に足す。
- 設計の流れは superpowers のスキル（brainstorming → writing-plans → test-driven-development）に従う。設計書は `docs/superpowers/specs/`、計画は `docs/superpowers/plans/` に置く。

## 秘密情報
- API キー、`.p8`、証明書、プロビジョニングプロファイルを、コード・コミット・CI ログ・チャットに置かない。
- Claude の API キーはアプリ内で入力し Keychain に保存する。
- 署名と App Store Connect のキーは Codemagic と App Store Connect の画面にだけある。エージェントは値を求めない。
- `.feedback/`（TestFlight のフィードバック。個人情報を含みうる）はコミットしない。

## 配信（TestFlight）
- `codemagic.yaml` のワークフロー「iOS TestFlight」を、人が Codemagic の画面から `main` を指定して手動で起動する。
- 初回設定と署名の手順は `docs/testflight-setup.md`。
- TestFlight のフィードバックは `tools/asc_feedback.py` で取得する（App Store Connect の API キーを環境変数で渡す。人の PC でだけ使う）。
