# iOS マルチモデルAIエージェント 要件定義書

- 文書ID: IOS-AGENT-REQ-001
- 版: 1.0（PoC/MVP向け）
- 作成基準日: 2026-10-17
- 想定開発者: Claude Codeを利用する個人開発者
- 正式アプリ名: 未定（仮称: Pocket Agent）
- ステータス: 開発着手用の初版。未確定事項は第15章に明記。

> **重要な前提**: 本製品は、iPhone本体でAgent Runtimeと対応ローカルLLMを実行する。Claudeモードはクラウド推論なのでオフライン動作とは呼ばない。また、iOSの公開APIでは他社アプリ（LINE等）の画面へ任意のタップ・文字入力を注入できない。本MVPは他アプリを無断操作するものではない。

## 1. 背景と目的

### 1.1 背景
- iPhoneだけで自然言語の指示を受け、複数ステップの仕事を進められるAIエージェントが欲しい。
- 推論モデルはClaude（クラウド）とApple Foundation Models／MLXベースモデル（端末内）から選びたい。
- 第一の具体的用途は、LINE向けの文章を生成し、ユーザー確認後にLINEの公式共有画面へ渡すこと。
- 開発端末はWindows/Linuxでも成立させたい。Macは所有していなくてもよいが、クラウド上のmacOSビルド環境を利用する。

### 1.2 MVPの成功定義
1. **単一のiPhoneアプリ**から、少なくとも1種類のClaude接続方式と1種類のオンデバイスLLM方式を選択できる。
2. 共通のAgent Runtimeでチャット、ツール実行計画、実行前承認、履歴保存、停止が動く。
3. 「○○に遅れる旨のLINE文を作成して」と指示すると、文章を生成し、ユーザーの承認を得てLINE公式の送信先選択画面に遷移できる。
4. ローカルモデル選択時にネットワークを遮断しても、対応端末上で文面生成およびアプリ内ツールが動く。
5. Macを保有しなくても、Git→クラウドmacOS CI→署名→TestFlight→iPhone実機テストの経路を構築できる。

### 1.3 対象ユーザー
- MVP: 開発者本人の個人利用。多人数向け商用サービスではない。
- 将来: 明示的な追加設計・審査を経た他ユーザーへの展開。

## 2. スコープと境界

### 2.1 MVP対象（Must）
- SwiftUIによるチャット画面、設定画面、実行履歴画面。
- AgentRunKitを基盤とするエージェントループ。
- Claude Messages API接続（正規のAPIキー、または公式にサポートされるApp Attest等の方式）。
- Apple Foundation Models経由のオンデバイスLLM。対応端末・OS・設定状態を事前判定する。
- モデル切り替え（最低限Claude ↔ Appleオンデバイス）。
- 型付きツール、実行前承認、キャンセル、反復上限、タイムアウト、エラーメッセージ。
- LINE公式URLスキームを用いた文面共有。送信先選択と送信操作は人間が行う。
- KeychainでのAPIキー等の保存、ローカル会話履歴の削除、ログの秘匿化。
- Windows/Linux主体で運用できるクラウドmacOSビルド／実機配信。

### 2.2 MVP後の優先拡張（Should）
- MLX（量子化された1B〜3B級の候補から実機検証して採用）を追加。
- モデルのダウンロード・削除・容量表示・整合性検証。
- iOS Share Extensionによるユーザー選択テキスト／画像の取り込み。
- 画像やスクリーンショットをユーザーが明示選択し、解析する機能。
- オフライン時のモデル切り替え提案、ツール一覧の管理、会話エクスポート。

### 2.3 対象外（Not in MVP）
- LINE個人アカウントのトーク履歴の勝手な取得、既読監視、返信の無人送信。
- LINEを含む他社アプリ画面への任意の座標タップ・スクロール・キー入力。
- OSの権限回避、非公開API、脱獄、アクセシビリティ権限を偽装する操作。
- バックグラウンドで無制限に常駐するエージェント。
- 任意のシェルコマンド実行、ローカルファイル全域への無制限アクセス。
- Claude Code CLIそのものをiOSに移植すること。
- プライベートOAuthトークンの抽出、Claude Codeのクライアント偽装、契約上不明な認証の迂回。

## 3. 技術構成

### 3.1 推奨技術
| 要素 | 採用方針 |
|---|---|
| アプリUI | SwiftUI |
| 言語 | Swift 6系、Swift Concurrency、strict concurrencyを段階的に有効化 |
| エージェントハーネス | AgentRunKit（初期検証対象: v6.1.0。CIで解決版をロック） |
| クラウドモデル | AgentRunKit `AnthropicClient` / Claude Messages API |
| ローカルモデル1 | `AgentRunKitFoundationModels`、Apple Intelligence対応端末のみ |
| ローカルモデル2 | `AgentRunKitMLX`、互換性・メモリ評価後に追加 |
| 永続化 | SwiftDataまたはローカルSQLite（実装初期に一方を選定） |
| 秘密情報 | iOS Keychain。ソース・設定ファイルへ直書き禁止 |
| CI | GitHub ActionsのmacOS runnerでビルド／ユニットテスト |
| 配信 | Codemagicで署名・TestFlight配信（または同等のクラウドmacOS CI） |
| プロジェクト生成 | XcodeGen等の宣言的構成を検討。Windowsからも設定を編集できる形式を優先 |

### 3.2 OSサポート
- **MVPターゲット: iOS 26以降**。Apple Foundation Modelsを主軸に据えるため。
- AgentRunKit本体はより古いOSを支援していても、Appleのオンデバイスモデルは別途利用要件がある。
- Apple Foundation Modelsが非対応・未有効・準備中なら選択肢を無効化し、理由を表示する。
- MLXの可用性は機種、RAM、OS、選んだモデルごとに実機で判定する。

### 3.3 論理アーキテクチャ
```text
SwiftUI (Chat / Settings / History / Approval)
  └── AgentCoordinator (状態管理・キャンセル・セッション)
       ├── ModelProviderAdapter
       │    ├── ClaudeAdapter    -> Anthropic Messages API
       │    ├── AppleLocalAdapter -> Foundation Models
       │    └── MLXAdapter       -> MLX（Phase 2）
       ├── AgentRunKit Agent (loop / tools / limits / streaming)
       ├── ToolRegistry + PermissionPolicy
       │    ├── PrepareLineMessageTool
       │    ├── OpenLineShareTool    -> LINE公式URL
       │    ├── ReadSelectedInputTool -> アプリへ明示的に渡した内容のみ
       │    └── SaveNoteTool         -> アプリ内保存のみ
       ├── HistoryRepository
       └── CredentialStore (Keychain)
```

**設計原則**: UI、モデル、ハーネス、ツール、認証を分離する。AgentRunKitの公開APIは導入時に確認し、README上の名称と異なる場合はAdapter層で吸収する。モデル間でツールのサポートや精度が違う場合、利用可否をUIに示す。

## 4. 機能要件（ID付き）

| ID | 優先 | 要件 | 受け入れ条件 |
|---|---|---|---|
| FR-01 | Must | テキストチャット | ユーザー入力→逐次応答表示→完了／失敗が分かる |
| FR-02 | Must | モデル選択 | ClaudeとAppleローカルを設定から切替できる |
| FR-03 | Must | 利用可否検査 | 非対応モデルは実行前に検知し理由を表示する |
| FR-04 | Must | エージェントループ | 複数ステップとツール呼び出しを実行し終了条件を持つ |
| FR-05 | Must | ツール実行承認 | 外部遷移・共有など副作用のある処理は承認なしに実行しない |
| FR-06 | Must | 停止・実行制限 | 取消、反復上限、時間・トークン予算の上限がある |
| FR-07 | Must | LINE文面作成 | 日本語で指示を解釈し修正可能な文面を提示 |
| FR-08 | Must | LINE共有 | ユーザー承認後 `https://line.me/R/share?text=...` を開く。送信結果は勝手に成功扱いしない |
| FR-09 | Must | 認証設定 | APIキー入力・接続確認・更新・削除ができる |
| FR-10 | Must | 履歴 | 会話とツール実行結果を端末内保存・個別削除可能 |
| FR-11 | Must | オフライン動作 | Appleローカル選択時、ネットワーク不要の対応機能が実行可能 |
| FR-12 | Must | CIビルド | Git pushでmacOS上のiOSビルドとテストが走る |
| FR-13 | Must | 実機配信 | 適切な署名設定でTestFlightへ配信可能 |
| FR-14 | Should | MLX対応 | 対応機種でモデルのロード・推論・解放ができる |
| FR-15 | Should | モデル資産管理 | ダウンロード、進捗、中断、削除、残容量警告がある |
| FR-16 | Should | Share Extension | ユーザーが明示的に共有した情報のみアプリへ取り込める |
| FR-17 | Should | 利用コスト表示 | クラウド推論の利用状況を取得可能な範囲で表示（推定は推定と明示） |

### 4.1 主要ユーザーストーリー
**US-01: LINE送信補助**
1. ユーザー「家族に10分遅れるってLINEしたい」と入力。
2. AIが丁寧さを調整した文面を生成する。
3. アプリに「編集」「コピー」「LINEで共有」が表示される。
4. 「LINEで共有」を押し、外部アプリ遷移の確認を表示する。
5. 承認後にLINEの「送信先を選択」画面を開く。
6. 送信先の選択と送信はユーザーがLINE側で行う。アプリは送信完了と断定しない。

**US-02: オフライン利用**
1. ユーザーはAppleローカルモデルを選ぶ。
2. 機内モードでもメッセージ文面の生成が完了する。
3. インターネットを要する外部ツールは「接続が必要」と表示する。
4. Claudeへの通信や密かなフォールバックを一切行わない。

**US-03: モデル切り替え**
1. ユーザーが設定からClaude/Appleローカルを選択する。
2. 新しいターンから選択が適用される。
3. 履歴は保持されるがモデル固有の内部セッション状態は適切に再生成する。
4. モデルが必要なツールをサポートしない場合、無理な呼び出しをせず明示する。

## 5. Claude Teamプラン／認証要件

1. **MVPの確実な認証経路**はAnthropic公式のClaude Messages API。個人PoCではユーザー自身のAPIキーをKeychainに保存する。
2. Teamプランに付属するAPIクレジットは、該当するClaude Consoleの組織設定・管理者によるリンク状況を確認して利用する。残高や適用条件を推測しない。
3. 製品配布を見据えた方式は公式のApp Attestまたは安全なバックエンド認証を別途評価する。AgentRunKitの`AnthropicClient`へどの方式を統合できるかはスパイクで検証する。
4. PCのClaude Code CLI／Claude Agent SDKでサブスクリプションログイン可能な事実は前提とする。ただし、そのログイントークンを独自iOSアプリで利用できる公式・契約上・技術上の根拠は未確定。**MVPでOAuthトークンを抜き出して流用しない**。
5. 認証方式を`CredentialProvider`インターフェースで抽象化し、将来公式サポートの認証経路が確認できた場合のみ追加する。
6. `CLAUDE_CODE_OAUTH_TOKEN`等の機密値はソース、README、CIログ、GitHub Actionsログ、クラッシュレポートに出力しない。
7. APIの課金・クレジット残高、Team組織の権限等は利用者が管理する。上限警告を用意する。

## 6. ローカルLLM要件

### 6.1 第一優先: Apple Foundation Models
- Apple Intelligenceが有効な対応端末でのみ利用可能。
- `availability`相当の公開APIで開始前に適格性と準備状態を確認する。
- テキスト生成、要約、文面修正、対応するツール呼び出しを対象とする。
- 履歴が長くなった場合はコンテキストの予算管理・圧縮を行う。

### 6.2 第二優先: MLX
- iOS実機でモデルがロードできることを技術検証してから正式採用。
- 量子化1B～3B級を候補とするが**特定モデル名と性能は未確定**。
- ダウンロード前に必要容量、ライセンス、通信量を表示する。
- メモリ不足時は推論を中断し、モデルをアンロードし、エラーを表示する。
- ツール呼び出しが安定しないモデルは「文章生成専用」モードに切り替える。

### 6.3 ローカルプライバシー
- 端末内モデルを選んだ会話本文をClaude等の外部APIへ送らない。
- ネットワークアクセスを必要とするモデル資産の初期ダウンロードは別操作として説明する。
- オフライン状態の受け入れテストに通信遮断を含める。

## 7. エージェントハーネス・ツール要件

- AgentRunKitのエージェントループ、ストリーミング、型付きTool、Tool Approval、上限管理を利用する。
- `ToolRegistry`で利用可能ツールを明示列挙し、モデル任せでOS能力を捏造しない。
- すべてのツールに`name`、`description`、入力JSON Schema、リスク区分、実行結果構造、タイムアウトを持たせる。
- 変更／共有／外部アプリ起動を伴うツールは原則として実行前承認。
- 初期上限: 1タスク最大10エージェントステップ（設定変更可能）、手動取消を常に表示。
- ループ、幻覚によるツール再実行、重複共有を抑止する。再実行は原則ユーザー操作。
- ツール実行状態は`proposed / awaitingApproval / executing / succeeded / failed / cancelled`として表示。
- `OpenLineShareTool`の成功は「共有先画面を開くOSリクエストが受け付けられた」まで。**メッセージ送信完了を保証しない**。
- iOSアプリでは汎用シェルとstdio MCPサーバーを前提にしない。MCPを使う場合はiOSと配布審査に適合する接続方式を別設計とする。

## 8. 画面要件

| 画面 | 内容 |
|---|---|
| ホーム／チャット | 入力欄、送信、モデル名、ストリーミング、タスク中断、ツール呼び出し内容 |
| 承認ダイアログ | 操作内容、対象、外部送信先、許可／拒否、許可の範囲 |
| 設定 | クラウド／ローカルのモデル選択、接続状態、API認証、情報削除 |
| 履歴 | 会話検索（後日でも可）、日時、実行結果、削除 |
| ローカルモデル管理（Phase 2） | 対応可否、モデル容量、ダウンロード、削除、メモリ注意 |
| エラー表示 | 認証失敗、利用制限、モデル非対応、通信不可、ツール失敗等の対処案内 |

- 初期UI言語は日本語。アクセシビリティ対応（Dynamic Type、VoiceOver）に配慮する。
- AIの文面は送信前に必ずユーザーが編集できる。

## 9. 非機能要件

### 9.1 セキュリティ
- APIキー・認証情報はKeychainへ格納。平文ファイル、UserDefaults、分析ログには残さない。
- 通信はHTTPS、TLS検証を弱めない。
- 秘匿情報をSwiftのデバッグ文字列、エラーメッセージ、CIログへ出さない。
- ツール呼び出し前に引数バリデーション。URLスキームの生成は`URLComponents`等を使用しUTF-8で安全にエンコード。
- リモートから取り込んだ文章・画像内の指示は信頼できない入力として扱い、ユーザー許可を上書きしない。

### 9.2 信頼性・性能
- エージェント処理はユーザーが途中キャンセルでき、停止後の未実行ツールは実行しない。
- タイムアウト・リトライはネットワーク呼び出しに限定し、送信・共有等の副作用は自動再試行しない。
- 目標値: UI操作の即時反応、クラッシュなしで一般的な短文タスクを完了。推論秒数は端末・モデル差が大きいため数値保証せず、実機測定から確定する。
- OSのメモリ警告に応じてMLXモデルを解放する。
- 端末ストレージ残量が不足する場合にモデルをダウンロードしない。

### 9.3 プライバシー
- ユーザー会話と履歴は原則ローカル保存。クラウド推論選択時のみ入力・必要な履歴を明示の上でClaudeへ送る。
- 解析ログは最小限。初期状態では会話本文を外部分析基盤へ転送しない。
- 「全データ削除」機能を備える。

## 10. 開発環境・Macなし運用

### 10.1 必須条件
- Windows/Linux PC上のClaude Code、Git、GitHubリポジトリ。
- クラウドmacOS runner上の互換Xcode/Swift環境。AgentRunKit v6.1.0はXcode 26以降を要する。正確な組み合わせはCIで固定する。
- iPhone実機。ローカルモデル検証ではApple Intelligence対応状況を確認する。
- TestFlight経由の配布にはApple Developer Program契約および署名・App Store Connect設定が必要。

### 10.2 推奨パイプライン
```text
Claude Code on Windows/Linux
    ↓ git push
GitHub repository
    ↓
GitHub Actions / macOS runner:
  Swift syntax/package/build/unit tests, optional simulator UI tests
    ↓
Codemagic / hosted macOS:
  signing → archive(.ipa) → App Store Connect → TestFlight
    ↓
iPhone real device:
  Cloud / Apple local / MLX / LINE integration test
```

- GitHub Actionsは署名不要ビルドと自動テストのゲートとして利用する。
- Codemagicは署名およびTestFlight配布の工程を担当する。共通化が進んだら一つのCI基盤へ統合してもよい。
- WindowsではXcode SimulatorとXcodeデバッガを直接動かせない。クラウドビルドログ・TestFlightのクラッシュログ・実機ログで代替するが、調査効率低下をリスクとして明記する。
- macOSを**一切使わず**ネイティブiOSアプリをビルドすることは本計画の前提としない。クラウドmacOSは必須。

## 11. テスト計画・受け入れ基準

| テストID | ケース | 合格条件 |
|---|---|---|
| AT-01 | Claude接続 | 有効キーで回答、無効キーで原因表示。キーはログに出ない |
| AT-02 | Appleローカル | 対応端末で文章生成。通信遮断下でも完了 |
| AT-03 | 非対応端末 | Appleモデルが使えない理由を提示。クラッシュしない |
| AT-04 | モデル切替 | Claude→ローカル→Claudeを切替し正常回答。前モードの認証を誤使用しない |
| AT-05 | ツール承認 | 「拒否」でLINEは開かず、副作用が起きない |
| AT-06 | LINE共有 | 「LINEで共有」で正しくエンコードした文字列が送信先選択画面に渡る |
| AT-07 | 誤送信防止 | アプリがLINEの送信済み状態を偽って表示しない |
| AT-08 | キャンセル | 実行途中で停止し、未承認のツールを実行しない |
| AT-09 | 上限 | エージェントが反復上限に達すると安全に終了する |
| AT-10 | 履歴削除 | アプリ内の会話・対象メタデータが削除される |
| AT-11 | セキュリティ | ダミーキーのコード／ログ／成果物混入を検出する |
| AT-12 | CI | Windowsからpush後、macOS runnerでビルド・テストが成功 |
| AT-13 | 配布 | 署名済み成果物をTestFlight経由で実機へインストールできる |
| AT-14 | ローカル通信 | ローカル推論を選んだときClaude API通信が発生しない |
| AT-15 | MLX（Phase 2） | 対応モデルがロード・推論・解放でき、メモリ不足時も安全終了 |

### 11.1 リグレッションテスト
- FakeLLMで固定されたツール呼び出しを再生し、実ネットワークなしでAgentの振る舞いをテストする。
- テストは成功系、拒否系、API失敗、同一ツールの再実行、URLエンコード、通信遮断、モデル未対応を含める。
- 実機テスト結果は機種、OS、メモリ、モデル名・量子化方式、操作時間を記録する。

## 12. 開発フェーズと完了条件

**Phase 0: 技術スパイク（最優先）**
- `AgentRunKit`を固定バージョンで取得し、クラウドmacOS CIでiOS向けビルド可否を確認。
- Claude Messages APIで1往復、Apple Foundation Modelsで1往復、型付きツールを1件呼び出す。
- 検証不能・互換性問題の際は「薄い独自Agent Runtime + Apple Foundation Models」を代替案として提案し、ユーザー承認を得る。黙って別フレームワークへ移行しない。
- **完了条件**: CIビルド成功・実機で2つのモデル経路を確認。

**Phase 1: MVP実装**
- チャット、設定、Keychain、ストリーミング、上限、承認、LINE共有、履歴、エラー処理。
- CI/TestFlightと受け入れテストAT-01〜AT-14。
- **完了条件**: LINE文面生成→承認→共有先選択まで実機で通過。認証情報漏えいなし。

**Phase 2: ローカル機能強化**
- MLX連携、量子化モデル評価、ダウンロード・メモリ管理、Share Extension。
- **完了条件**: 選定端末での安定性評価を満たす。AT-15合格。

**Phase 3: 将来拡張（別途要件定義）**
- 外部サービスAPIとの連携、より高度なスキル管理、追加モデル、適切な画面共有／OCR。
- 他社アプリへの自動タップ実装を前提条件にしない。

## 13. リスクと対応

| リスク | 影響 | 対応 |
|---|---|---|
| AgentRunKitのAPI変更／新興OSSとしての不安定さ | 高 | 依存バージョンを固定・Adapterで隔離・Phase 0検証 |
| TeamサブスクOAuthの独自iOSアプリ対応が不確実 | 高 | MVPは公式API認証に限定。契約・公式サポートを確認 |
| LINE自動タップ不可 | 高 | 公式共有画面＋ユーザー送信を仕様として明示 |
| iPhone機種によりローカルモデル非対応 | 中 | 可用性判定・動的にモデル非表示・代替を案内 |
| MLXのメモリ不足／発熱 | 中 | 小型量子化モデル・容量管理・キャンセル・解放 |
| Macなしのデバッグ効率低下 | 中 | 小さいPR、CI、実機配信、ログ収集、テスト自動化 |
| モデルからの不正なツール実行提案 | 高 | ツールallowlist・入力検証・実行承認・権限分離 |
| API費用の想定外増加 | 中 | クラウドモードを明示・予算警告・上限設定 |

## 14. Claude Codeへの実装指示・Definition of Done

1. まずこの要件定義書を読み、Phase 0から始める。実装前に既存リポジトリの状態を確認する。
2. `docs/architecture.md`、`docs/decisions.md`、`docs/test-plan.md`を作成し、主要判断と不確実事項を残す。
3. アプリ・ドメイン・モデルアダプター・ツール・永続化を分離し、DI可能なインターフェースにする。
4. ネット接続不要のFakeLLMを先に実装してツール承認をユニットテスト可能にする。
5. `AgentRunKit`のREADMEだけでAPIを推測せず、固定バージョンの実コード・ビルド結果で確認する。
6. `git push`ごとにiOSビルドとユニットテストが実行されるCIを提供する。署名秘密情報をコミットしない。
7. 実装した機能・未実装機能・制約・手動検証手順をREADMEに記載する。
8. LINEの送信完了・他アプリ操作・Teamトークン認証について、未実現なのに実現と報告しない。
9. すべてのMust要件の受け入れ基準に証跡（CIログ・実機テスト記録）を持たせる。
10. 仕様変更は要件ID・影響・理由・テストを併記する。

## 15. 未確定事項（開発開始時の暫定方針）

| 項目 | 暫定決定 |
|---|---|
| 利用iPhone機種 | 未確認。Appleローカル対応の実機をPhase 0ゲートにする |
| Claude Teamの組織・クレジット設定 | 未確認。MVPは個人APIキーで技術検証、クレジット適用は別確認 |
| iOSアプリの公開方針 | 当面個人利用/TestFlight。App Store一般公開は後日判断 |
| MLXのモデル名 | 実機の空きRAM／ストレージと精度評価で選定 |
| データ永続化 | SwiftData優先、CIや拡張性の検証でSQLiteに切替可 |
| クラウドビルドサービス | GitHub Actions + Codemagicを基準。Xcode環境適合・費用を検証 |
| バージョンピン留め | 2026-10-17時点のAgentRunKit v6.1.0を候補。実ビルドで確定 |
| 推論応答速度SLO | 実機測定後に設定。根拠のない固定値は採用しない |

## 16. 公式・一次参照資料

- AgentRunKit: https://github.com/Tom-Ryder/AgentRunKit
- Swift Package Index: https://swiftpackageindex.com/Tom-Ryder/AgentRunKit
- Apple Foundation Models: https://developer.apple.com/foundation-models-framework/
- Appleのモデル利用可否: https://developer.apple.com/documentation/FoundationModels/SystemLanguageModel
- Anthropic API認証: https://platform.claude.com/docs/en/manage-claude/authentication
- ClaudeサブスクとAgent SDK: https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- サードパーティー認証ガイダンス: https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account
- LINE URLスキーム: https://developers.line.biz/ja/docs/messaging-api/using-line-url-scheme/
- Xcode動作環境: https://developer.apple.com/xcode/system-requirements
- GitHub macOS runner: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- Codemagic ネイティブiOS: https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/
- Codemagic署名: https://docs.codemagic.io/yaml-code-signing/signing-ios/

---

この文書は実装の基準であり、iOSで許可されていない操作を要求する根拠にはしない。Phase 0でAPI・ビルド・実機対応可否を検証し、結果に基づき必要な変更を記録する。
