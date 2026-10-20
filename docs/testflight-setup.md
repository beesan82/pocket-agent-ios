# TestFlight 配信セットアップ（Codemagic）

リポジトリ側（`codemagic.yaml`、アイコン、`ITSAppUsesNonExemptEncryption = NO`、ビルド番号の自動採番）は準備済み。
以下はユーザーが各サービスの画面で行う作業。**APIキー（.p8）・Issuer ID・Key ID はチャットやリポジトリに貼らない**（Codemagic の画面にだけ登録する）。

## 1. Bundle ID を決めて登録する
1. Bundle ID は **`com.beesan82.pocketagent`**（決定済み・`project.yml` と `codemagic.yaml` に反映済み）。
2. developer.apple.com → Certificates, IDs & Profiles → Identifiers → ＋ → App IDs → App → Explicit で上の Bundle ID を登録（Capabilities は追加不要）。

## 2. App Store Connect にアプリを作る
1. appstoreconnect.apple.com → アプリ → ＋ → 新規アプリ
   - プラットフォーム: iOS / 名前: Pocket Agent（使用済みなら「Pocket Agent Dev」など）/ 言語: 日本語 / バンドルID: 手順1のもの / SKU: `pocketagent`
2. 作成済み（Apple ID `6824194188`、`codemagic.yaml` の `APP_STORE_APPLE_ID` に反映済み）。

## 3. App Store Connect API キーを作る
1. App Store Connect → ユーザとアクセス → 統合 → App Store Connect API → チームキー → ＋
   - 名前: `Codemagic Pocket Agent` / アクセス: **App Manager**
2. `.p8` をダウンロード（1回しかダウンロードできない）。Issuer ID と Key ID を控える。

## 4. Codemagic を設定する
1. codemagic.io に GitHub アカウントでサインアップし、GitHub App に `beesan82/pocket-agent-ios` へのアクセスを許可する。
2. Team settings → Team integrations → Developer Portal → Manage keys → Add key
   - **App Store Connect API key name: `Pocket Agent ASC`**（`codemagic.yaml` と完全一致させる）
   - Issuer ID / Key ID / `.p8` を登録
3. Applications → Add application → GitHub → `pocket-agent-ios` → 設定方法は `codemagic.yaml` を選ぶ。

## 4.5 署名ファイルを用意する（ビルド時に自動作成はされない）
Codemagic の `ios_signing` は、事前に登録された証明書とプロファイルを探して使うだけ。無いと
「No matching profiles found for bundle identifier ... and distribution type "app_store"」で止まる（2026-10-18 実際に発生）。
1. Codemagic → Settings → codemagic.yaml settings → Code signing identities → iOS certificates → Generate certificate
   （Reference name `pocketagent-dist` / Apple Distribution / キー `Pocket Agent ASC`）。ダウンロードは1回だけ。一覧に無ければ Upload certificate で登録。
2. developer.apple.com → プロファイル → ＋ → 配信「App Store Connect」→ App ID `com.beesan82.pocketagent` → 手順1の証明書 → 名前 `Pocket Agent App Store` → 生成。
3. Codemagic → Code signing identities → iOS provisioning profiles → Fetch profiles → `Pocket Agent App Store` を選択（Reference name `pocketagent-appstore`）→ Download selected。

## 4.6 Metal Toolchain（Phase 2 以降、MLX を含むビルドに必須）
Xcode 26 では Metal コンパイラが別コンポーネントになり、Codemagic のイメージには入っていない。MLX の `.metal` ファイルのコンパイルで
「cannot execute tool 'metal' due to missing Metal Toolchain」と失敗する（2026-10-19 に発生）。`codemagic.yaml` の先頭ステップで
`xcodebuild -downloadComponent MetalToolchain` を実行して取得する（毎ビルド数分かかる）。GitHub Actions の macos-26 イメージには同梱済みだったが、xcode-27 イメージには無いため CI でも取得する（ADR-030）。

## 5. ビルドを実行する
1. Codemagic → Pocket Agent → Start new build → ブランチ `main` / ワークフロー **iOS TestFlight**。
2. 成功すると App Store Connect の TestFlight に処理中のビルドが現れる（処理に数分〜数十分）。
3. TestFlight → 内部テスト → グループを作り自分を追加 → iPhone の TestFlight アプリからインストール。

## 注意
- このワークフローは手動起動のみ（push では動かない）。Codemagic の無料枠（個人向け macOS の月間分数）を節約するため。
- 失敗したら Codemagic のビルドログ（`xcodebuild_logs`）を Claude に共有する。キーの値は含まれないが、念のため貼る前に確認する。
- 実機で確認したことは `docs/phase0-checklist.md` の「実機で未検証」リストに沿って記録する。
