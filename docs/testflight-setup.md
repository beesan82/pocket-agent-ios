# TestFlight 配信セットアップ（Codemagic）

リポジトリ側（`codemagic.yaml`、アイコン、`ITSAppUsesNonExemptEncryption = NO`、ビルド番号の自動採番）は準備済み。
以下はユーザーが各サービスの画面で行う作業。**APIキー（.p8）・Issuer ID・Key ID はチャットやリポジトリに貼らない**（Codemagic の画面にだけ登録する）。

## 1. Bundle ID を決めて登録する
1. Bundle ID を決める（例: `<音楽アプリと同じプレフィックス>.pocketagent`）。決まったら Claude に伝える → `project.yml` と `codemagic.yaml` の `com.example.pocketagent` を置き換える。
2. developer.apple.com → Certificates, IDs & Profiles → Identifiers → ＋ → App IDs → App → Explicit で上の Bundle ID を登録（Capabilities は追加不要）。

## 2. App Store Connect にアプリを作る
1. appstoreconnect.apple.com → アプリ → ＋ → 新規アプリ
   - プラットフォーム: iOS / 名前: Pocket Agent（使用済みなら「Pocket Agent Dev」など）/ 言語: 日本語 / バンドルID: 手順1のもの / SKU: `pocketagent`
2. 作成後「アプリ情報」の **Apple ID（数字）** を Claude に伝える → `codemagic.yaml` の `APP_STORE_APPLE_ID` に入れる（秘密情報ではない）。

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

## 5. ビルドを実行する
1. Codemagic → Pocket Agent → Start new build → ブランチ `main` / ワークフロー **iOS TestFlight**。
2. 成功すると App Store Connect の TestFlight に処理中のビルドが現れる（処理に数分〜数十分）。
3. TestFlight → 内部テスト → グループを作り自分を追加 → iPhone の TestFlight アプリからインストール。

## 注意
- このワークフローは手動起動のみ（push では動かない）。Codemagic の無料枠（個人向け macOS の月間分数）を節約するため。
- 失敗したら Codemagic のビルドログ（`xcodebuild_logs`）を Claude に共有する。キーの値は含まれないが、念のため貼る前に確認する。
- 実機で確認したことは `docs/phase0-checklist.md` の「実機で未検証」リストに沿って記録する。
