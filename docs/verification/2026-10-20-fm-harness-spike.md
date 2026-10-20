# 実機検証手順: Foundation Models ハーネス スパイク（第2段階の入口）

**結果が出るまで未検証。** 結果記入欄が埋まるまで、どの項目も「通った」とは報告しない。
**捨てる前提のコード。** `spike/fm-harness` ブランチだけにあり、main には入れない。

## 目的
- 設計 docs/superpowers/specs/2026-10-19-agentic-tools-all-models-design.md の「第2段階の入口: スパイク定義」の項目 1〜5 を実機で確かめる。
- 判断基準（設計書から）: **1・2・4 が通れば第2段階の設計へ進む。** 3 が通らなければ、ローカルは当面 AgentRunKit の `MLXClient` を残す「併用」設計。**1 が iPhone 15 で通らなければ第2段階は見送り。**

## スパイクアプリ（FM Spike）の中身
- 場所: `spike/`（XcodeGen の別プロジェクト `spike/project.yml`、ソースは `spike/FMHarness/`）。
- 本体アプリとは別プロジェクトにした理由: MLX の Foundation Models 統合（`MLXFoundationModels`）は mlx-swift-lm **3.32.3** にしか無く、AgentRunKit 6.1.0 は mlx-swift-lm を `.upToNextMinor(from: "2.30.0")` で固定しているため、同じアプリに両方を入れられない（どちらもソースで確認済み）。
- 採用版: ClaudeForFoundationModels **0.2.3**（anthropics、Beta）、mlx-swift-lm 3.32.3、mlx-swift 0.32.x、swift-huggingface ≥0.9.0、swift-transformers ≥1.3.0。deploymentTarget iOS 27.0。
- バンドル ID は本体と同じ `com.beesan82.pocketagent`。TestFlight の同じアプリ記録に「FM Spike」という表示名のビルドとして上がる。**入れると本体アプリが置き換わる**（データ領域は残る）。検証が済んだら TestFlight で本体の最新ビルドを入れ直す。
- 1 画面だけのアプリ:
  - 端末欄: 機種 ID（例 `iPhone15,4`）、iOS 版、`SystemLanguageModel.default.availability`。
  - バックエンド: `Claude (.apiKey)` / `Claude (.appAttest)` / `SystemLanguageModel` / `MLX Qwen2.5 1.5B`。Claude のモデルは `claude-haiku-5-5`。
  - 全バックエンドに同じ `SaveNoteTool`（`save_note {text}`）を渡す。`Tool.call` の中で承認シートを出して待つ。拒否なら保存しない。待っている間にキャンセルされたら `CancellationError` を投げる。
  - `.apiKey` は Pocket Agent と同じ Keychain 項目（service `com.beesan82.pocketagent.anthropic` / account `api-key`）から読む。本体で保存済みならそのまま使える。無ければ画面で保存できる。
  - セッションはバックエンドごとに 1 つを使い回す（複数ターン）。「新しいセッション」で捨てる。
  - ログ欄: `Tool.call` の開始・承認待ちの秒数・結果、返答、エラー、所要時間、`isResponding`、トランスクリプトの件数とツール呼び出し名。MLX は `Memory.activeMemory` と `os_proc_available_memory`。「ログをコピー」でクリップボードへ。

## ビルド
1. CI（GitHub Actions `xcode-27` ランナー、ジョブ `spike-fm-harness`）でシミュレータ・実機向けの未署名ビルドが通ることを先に確認する。
2. Codemagic でワークフロー **FM Spike TestFlight**（`spike-fm-testflight`）をブランチ `spike/fm-harness` で手動実行する。
   - Codemagic の `xcode: latest` が Xcode 27 でなければ、最初のステップで止まる（その場合は Codemagic の Xcode 版の指定を見直す）。
   - 項目 5 用のビルドだけは環境変数 `SPIKE_APP_ATTEST=1` で実行する（下の「項目 5 の準備」が先）。
3. iPhone 15（iOS 27 に更新済み）と iPhone 18,5（iOS 27.0）に TestFlight から入れる。

## 手順
各項目の終わりに「ログをコピー」し、結果記入欄に貼る（API キーはログに出ない）。

### 項目 1: Claude + Tool の承認待ち（iPhone 15 と iPhone 18,5 の両方）
1. バックエンド `Claude (.apiKey)` を選ぶ。「Keychain: キーあり」になっているか確認する。
2. 「私の名前はケイタ 覚えておいて」を送る。
   - 期待: 承認シート（save_note の承認 / 本文）が出る。ログに `Tool.call save_note text=...` が出る。
3. 10 秒ほど待ってから「保存する」を押す。
   - 期待: ログに `Tool.call approved after 10.x s → saved`、続いて `← ...` に返答が出る。「保存されたメモ」に 1 件増える。タイムアウトのエラーが出ない。
4. もう一度送り、今度は「拒否」を押す。
   - 期待: メモは増えず、返答が「保存しなかった」旨になる。
- 合格条件: iPhone 15 で手順 2〜4 がすべて期待どおり（iPhone 15 は Apple Intelligence 非対応なので、ここが第2段階の可否を決める）。

### 項目 2: SystemLanguageModel（iPhone 18,5）
1. 端末欄の availability が `available` であることを確認する（iPhone 15 では unavailable が期待値。その値を記録する）。
2. バックエンド `SystemLanguageModel` で項目 1 の手順 2〜4 を行う。
- 合格条件: 承認シートが出て、承認で保存・拒否で未保存になる。ツールが呼ばれず本文に JSON を書いた場合は「不合格（ツール呼び出しなし）」と記録し、返答本文をそのまま貼る。

### 項目 3: ローカルモデル（MLX Qwen2.5 1.5B、iPhone 18,5。余裕があれば iPhone 15 も）
1. Wi-Fi 接続で `MLX Qwen2.5 1.5B` を選び、「モデルを読み込む (preload)」を押す（初回は約 0.9 GB のダウンロード）。
   - ログに読込前後のメモリが出る。Phase 2-0 の計測（docs/phase2-mlx-eval.md: Qwen2.5 1.5B 読込後 831 MB、利用可能 2066 MB）と比べる。
2. 項目 1 の手順 2〜4 を行う。
- 合格条件: 読み込みが終わり、`save_note` が呼ばれて承認シートが出る。メモリ警告やアプリ終了が無い。
- `apple/coreai-models` 経由は今回のスパイクでは実装していない（未着手。mlx-swift-lm 統合が通らなかったときの次の候補）。

### 項目 4: 複数ターンとキャンセル（Claude と SystemLanguageModel で）
1. 項目 1 の承認後、同じセッションのまま「私の名前は？」と送る。
   - 期待: 「ケイタ」と答える（トランスクリプト保持）。ログの `transcript entries=` が前回より増えている。
2. 「新しいセッション」を押してから「私の名前は？」と送る。
   - 期待: 答えられない（トランスクリプトが捨てられた対照）。
3. 「牛乳を覚えておいて」を送り、承認シートが出たら「保存する」「拒否」は押さず、シート下部の **「応答をキャンセル（承認待ちのまま）」** を押す。
   - 期待: ログに `Tool.call cancelled after ...`、`respond threw CancellationError`（または同等のエラー）、`isResponding=false`。メモは増えない。
4. 続けて同じセッションで「私の名前は？」を送る。
   - 期待: キャンセル後もセッションが使え、答えが返る。
- 合格条件: 1・3・4 が期待どおり（AT-08 相当）。

### 項目 5: App Attest（iPhone 15）
**項目 5 の準備（人の操作が要る）:**
1. Apple Developer の Identifiers で `com.beesan82.pocketagent` に **App Attest** の capability を付け、App Store プロファイルを作り直して Codemagic で Fetch する。
2. Claude Console の App integrations（https://platform.claude.com/settings/workspaces/default/app-integrations）で Team ID とバンドル ID を登録し、client ID（`clid_...`）を得る。client ID は公開してよい設定値。
3. Codemagic で `SPIKE_APP_ATTEST=1` にして FM Spike TestFlight を実行し、入れ直す。
**手順:**
1. `Claude (.appAttest)` を選び、client ID を入力して「authenticateIfNeeded()」を押す。
   - 期待: `appAttest authenticateIfNeeded OK`（初回は数秒）。
2. 項目 1 の手順 2〜3 を行う。
- 合格条件: 1 往復（ツール呼び出しを含む）が成功する。

## 結果記入欄
| 項目 | 端末 / iOS | ビルド番号 | 結果（合格 / 不合格 / 未実施） | ログ・備考 |
|---|---|---|---|---|
| 1 Claude + 承認待ち | iPhone 15 / | | 未実施 | |
| 1 Claude + 承認待ち | iPhone 18,5 / | | 未実施 | |
| 2 SystemLanguageModel | iPhone 18,5 / | | 未実施 | |
| 2 availability | iPhone 15 / | | 未実施 | |
| 3 MLX Qwen2.5 1.5B | iPhone 18,5 / | | 未実施 | メモリ: |
| 4 複数ターン | | | 未実施 | |
| 4 キャンセル | | | 未実施 | |
| 5 App Attest | iPhone 15 / | | 未実施 | |

## 判断（結果が埋まってから書く）
- 1（iPhone 15）・2・4 が合格 → 第2段階の設計へ。
- 3 が不合格 → ローカルは AgentRunKit `MLXClient` との併用設計。
- 1 が iPhone 15 で不合格 → 第2段階は見送り。MLX へのツール配置は AgentRunKit 上の自前ループとして別に設計する。
