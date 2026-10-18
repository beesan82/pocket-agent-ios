# 開発者モード: 測定ログを GitHub Issue として送る

実機で取った測定ログを、コピー＆貼り付けの代わりにワンタップで非公開リポジトリの Issue として送る機能です。
送信は、開発者モードをオンにし、トークンを保存し、確認ダイアログで「送信」を押したときだけ行われます。
ログには音声テストで話した内容が含まれるため、送信先は必ず非公開リポジトリにしてください。

## 1. 非公開リポジトリを作る

1. GitHub で新しいリポジトリ `pocket-agent-measurements` を作成する。
2. Visibility は **Private** にする（Public にしないこと）。

## 2. Fine-grained トークンを作る

1. GitHub の Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token。
2. Repository access は **Only select repositories** を選び、`pocket-agent-measurements` だけを選ぶ。
3. Permissions → Repository permissions → **Issues: Read and write**。他の権限は付けない。
4. Expiration は 90 日にする。
5. 生成されたトークンは、**iPhone 上でだけ**貼り付ける。チャット・メモ・Git・CI のログには貼らない。

## 3. アプリで設定する

1. 設定 → 開発者 → 「開発者モード」をオンにする。
2. 「GitHub トークン」に貼り付けて「保存」。状態が「保存済み」になる。トークンは端末の Keychain にだけ保存され、画面には再表示されない。
3. 「送信先リポジトリ」を確認する（既定: `beesan82/pocket-agent-measurements`）。
4. 設定 → MLX 検証 →「測定ログ」→「GitHub に送信」→ 確認ダイアログで「送信」。
5. 成功すると「送信しました（Issue #N）」と表示される。

ログが 60000 文字を超える場合は、先頭 4 行（ヘッダー）と新しい行だけを送り、省略した行数を明記する。

## 4. Claude がログを読む方法

PC で `gh` を使って読む。

```
gh issue list -R beesan82/pocket-agent-measurements
gh issue view <番号> -R beesan82/pocket-agent-measurements
```

## 5. 取り消す方法

- アプリ側: 設定 → 開発者 → トークンの「削除」。
- GitHub 側: Settings → Developer settings → Personal access tokens → Fine-grained tokens → 該当トークンを Delete（失効）。
- 不要になった Issue はリポジトリ側で Close / Delete する。
