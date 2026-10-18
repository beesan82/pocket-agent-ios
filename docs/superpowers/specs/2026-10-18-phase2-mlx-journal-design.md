# Phase 2 設計: 端末内 LLM（MLX）で動く音声・テキスト日誌

日付: 2026-10-18 / 対象要件: FR-11, FR-14, FR-15, AT-02（端末内）, AT-15、要件 6.2・6.3
前提: Phase 1 完了（チャット・メモ・LINE 返信・SwiftData・TestFlight 配信）。実機は **iPhone 15（6GB RAM、Apple Intelligence 非対応）**。

## 意図と背景（ユーザーの言葉から）
- 「Claude の API キーは従量課金なのでやりたくない」→ 端末内の AI を**当面のメイン**にする。
- 「音声記録を要約しておきたい。日誌をつけたい」「音声以外でもテキスト入力もする」→ 入口は音声とテキストの両方。短い一言も、寝る前の長い話も同じ扱い。
- 見返し方は「なにしてたかを振り返りたい」「あれ系の話どうなったっけ」で、**AI エージェントに聞く**（一覧を眺めるのではない）。
- 既存のメモ機能は日誌に吸収する。チャット／LINE 返信画面は Phase 2 では触らない（ユーザー了承）。

## ゴール
- G1 **記録**: 録音ボタンまたはテキスト欄から入力 → 端末内で文字起こし → 必要なら端末内 LLM が要約と見出しを付ける → ユーザーが確認してから保存。原文も残す。
- G2 **聞く**: 「先週なにしてた？」「〇〇の件どうなった？」に、保存済みの日誌を根拠にして端末内 LLM が答える。使った日誌をその場で示す。
- G3 **モデル管理**: ダウンロード（容量・ライセンス・通信の明示、空き容量チェック、進捗、中断）、削除、状態表示、メモリ警告時の解放（FR-15）。
- G4 **オフライン**: モデルと音声アセットが入っていれば機内モードで G1・G2 が動く。Claude へは一切通信しない（AT-14 と同じ原則）。
- G5 Phase 2-0 の**実機ゲート**: モデルが iPhone 15 で読み込め、日本語要約が使い物になるかを先に測ってから作り込む（要件 6.2）。

## 非ゴール
- 端末内 LLM によるツール呼び出し（メモ保存ツールなど）。小さいモデルでは不安定なので、保存・検索は**アプリ側が実行**する。
- チャット画面での MLX 利用、MLX と Claude の併用、日誌からの LINE 返信作成（次フェーズ候補）。
- 音声ファイルの保存、iCloud 同期、Share Extension、日本語以外の文字起こし、話者分離。

## アンチゴール（動いても失敗）
- 日誌の本文や質問が Anthropic 等の外部へ送られる。
- モデルや音声アセットのダウンロードが、ユーザーの明示操作なしに始まる。
- 「要約できなかった」「モデルがない」ときに記録自体が保存できない（**原文の保存は常に可能**）。
- 日誌にない内容を、根拠表示なしに答える（根拠の日誌を必ず併記する）。
- メモリ不足でアプリが落ちる（警告でモデルを解放し、文言を出す）。
- シミュレータで MLX を呼んでクラッシュする（CI は落ちないこと）。

## 事実確認（SDK・OS。設計の根拠）
- **AgentRunKitMLX 6.1.0** `MLXClient(container:model:contextWindowSize:parameters:)` は `LLMClient` で、`generate` は `UserInput(messages:tools:)` → `container.prepare` → `container.generate` を回して本文とツール呼び出しを返す。**`ContentOnlyTerminatingClient` に準拠していない**ので `Agent`/`AgentRunner` 経由ではテキスト応答で終了せず反復上限まで回る → **MLX は `AgentRunner` を使わず、`client.generate` を直接 1 往復ずつ呼ぶ**。`stream` もある（要約の逐次表示に使える）。
- **mlx-swift-lm 2.30.6**（ピン留め済み）: `loadModelContainer(hub: HubApi, configuration: ModelConfiguration(id:revision:), progressHandler: (Progress)->Void)`。保存先は `HubApi(downloadBase:)` の `downloadBase/models/<repo id>`（`localRepoLocation`）。既存ファイルはハッシュ一致で再ダウンロードしない。`ModelContainer` は `final class ... Sendable`（actor ではない）。`GenerateParameters(maxTokens:temperature:topP:repetitionPenalty:...)`。`Generation` は `.chunk/.toolCall/.info(promptTokenCount, generationTokenCount, tokensPerSecond)`。
- **mlx-swift 0.30.6**: メモリ API は `Memory.cacheLimit`、`Memory.clearCache()`、`Memory.activeMemory`、`Memory.memoryLimit`。**iOS シミュレータは非対応**（実行すると不可解なクラッシュ。保守側も当面サポートしない方針）。コンパイルは通る（Package.swift にシミュレータ除外なし）。
- **Speech (iOS 26)**: `SpeechAnalyzer` + `SpeechTranscriber(locale:preset:)`。`SpeechTranscriber.isAvailable` と `supportedLocales`（ja-JP を含む）で可否判定。アセットは `AssetInventory.assetInstallationRequest(supporting:)?.downloadAndInstall()` で導入。アセットは OS 共有でストレージ逼迫時に消されることがある → **毎回開始前に確認**。旧 `SFSpeechRecognizer` の約 1 分制限はない。
- **増量メモリの entitlement** `com.apple.developer.kernel.increased-memory-limit`（iOS 15+、対応端末のみ、`os_proc_available_memory()` で実測）。1.5B 4bit（重み約 0.9GB）なら既定上限で足りる見込み → **最初は付けない**。OOM が出たら追加する（プロファイル再生成が必要）。
- 候補モデル（Hugging Face `mlx-community`、Apache-2.0）:
  - **既定: `mlx-community/Qwen2.5-1.5B-Instruct-4bit`**（約 869MB。元モデルは日本語を公式サポート、文脈 32k）。
  - 代替: `mlx-community/Qwen3-1.7B-4bit`（約 968MB。thinking モードを無効化する必要があり、mlx-swift-lm のチャットテンプレートで `enable_thinking=false` を渡せるかは**未確認**。確認できるまで採用しない）。
  - 候補はコード内のレジストリ（名前・repo・revision・概算サイズ・ライセンス・備考）に列挙し、設定で切替可能にする。

## 構成（決定事項）

### 日誌データ（Core + App）
- Core: `JournalEntry { id: UUID; createdAt: Date; source: .voice | .text; origin: .journal | .noteTool; body: String; transcript: String?; title: String? }`。`body` は表示本文（要約があれば要約、なければ原文）。`transcript` は要約したときの原文。
- `protocol JournalStore` : add / all（新しい順）/ search(query) / entries(in: DateInterval) / entry(id:) / delete(id:) / deleteAll。検索は `NoteSearch.matches` を再利用。
- `JournalEntry` に `origin: .journal | .noteTool` を持たせる。`.journal` は日誌画面（音声・テキスト）から保存したもの、`.noteTool` は Claude チャットの `save_note` が保存したもの。
- 既存の `NoteStore`・`NoteTools`・メモ画面は、**日誌ストアの上に載せ替える**（Note = JournalEntry の射影）。ただし **Claude のメモツール（list/search/delete）が見るのは `.noteTool` の項目だけ**。`.journal` の本文は Claude に渡さない（アンチゴール「外部へ送られる」と要件 6.3 のため）。MLX の「聞く」は両方を読む。移行: 既存 `NoteRecord` は起動時に `JournalEntryRecord(source: .text, origin: .noteTool)` へ一度だけコピーして元を削除（件数が少ない前提。失敗時は元を残す）。
- SwiftData: `JournalEntryRecord`。`VersionedSchema` を Phase 2 で導入する（Phase 1 バックログ M6）。

### 記録フロー（App）
- ホーム = 日誌画面（日付でグループ化、新しい順、上部に検索欄、下部に **録音ボタン** と **テキスト欄**）。
- 録音: `AVAudioEngine` → `SpeechAnalyzer`/`SpeechTranscriber(ja-JP)`。途中結果（volatile）を薄く、確定結果を濃く表示。停止で確定。マイク権限・音声認識権限の説明文（`NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription`、日本語）。アセット未導入なら「ダウンロードしますか（通信が発生）」を出し、ユーザーのタップで `downloadAndInstall`。
- 確認画面: 文字起こし／入力テキストを編集可。**本文が 200 文字以上かつモデルが準備済み**なら自動で要約を実行（逐次表示、停止可）。要約結果と見出しは編集可。「保存」で `body` = 要約（要約していなければ原文）、`transcript` = 原文（要約時のみ）。「原文のまま保存」ボタンを常に出す。
- 要約プロンプト（単発、system + user の 2 メッセージ）: 日本語／箇条書きでなく 1〜3 文／固有名詞・日時・数字を落とさない／見出しは 15 文字以内／出力形式は固定（1 行目 `見出し: …`、2 行目以降が本文）。解析失敗時は要約全文を本文、見出しなし。

### 聞くフロー（App + Runtime）
- 画面「日誌に聞く」: 質問入力 → 回答（逐次表示）→ **根拠にした日誌**（日付・冒頭）を下に列挙。「停止」。
- 2 段階パイプライン（Runtime の純粋ロジック + `any LLMClient`）:
  1. **検索条件の抽出**（LLM 1 往復）: 「JSON 配列で検索語だけを出力」。パース失敗・空なら**保険**: 質問文を空白で分割した語 + 質問文そのもの。加えて、質問中の相対日付語（今日／昨日／今週／先週／今月／先月）を Core の純粋関数で `DateInterval` に変換（これは LLM に頼らない）。
  2. **検索はアプリ側で実行**（純粋関数でテストする）:
     - 日付範囲が取れたら **母集合 = その範囲の全件**。検索語は母集合を**絞り込むだけ**で、1 件も当たらなければ母集合をそのまま使う（「先週なにしてた？」は範囲全件で答える）。
     - 日付範囲がなければ、各検索語で `search` した結果の和集合（OR）。
     - 検索語は LLM の JSON 配列（単語でも句でもよい。各要素をそのまま 1 検索語にする）。保険の検索語は、質問文を空白と句読点（、。？！?!）で分割した断片（2 文字以上）。
     - それでも 0 件なら **直近 10 件**を母集合にして回答する（回答文の先頭で「直近の日誌から」と断る）。
     - 新しい順、最大 20 件、各件 300 文字まで、合計 3000 文字まで。
  3. **回答生成**（LLM 1 往復）: 「以下の日誌だけを根拠に日本語で答える。書いていなければ『日誌に記録がありません』と答える」+ 日誌 + 質問。
- 日誌が 1 件もないときだけ LLM を呼ばず「日誌がまだありません」。

### MLX ランタイム（App/Adapters + Runtime）
- `MLXModelRegistry`（候補一覧）、`MLXModelStore`（ダウンロード・削除・状態。保存先は `Application Support/Models` 配下の `HubApi(downloadBase:)`。進捗は `Progress`。中断はタスクキャンセル）。ダウンロード前の表示: サイズ・ライセンス・「通信が発生します」。空き容量が **サイズ × 1.5 未満なら開始しない**（要件 9.2）。
- ダウンロードは**フォアグラウンドのみ**（バックグラウンド URLSession や再開対応はこのフェーズでは作らない）。画面を離れてもアプリが前面にある間は続く。中断されると未完了ファイルは最初からになる（完了済みファイルはハッシュ一致で再取得しない）。モバイル回線（`NWPathMonitor` の `isExpensive`）のときは開始前に「Wi-Fi を推奨」を表示して確認する。
- `MLXRuntime`（`@MainActor @Observable`）: 状態 `notDownloaded / downloading(progress) / ready / loading / loaded / failed(reason)`。`load()` で `loadModelContainer` → `MLXClient(container:model:parameters:)`。`unload()` は参照を捨てて `Memory.clearCache()`。`UIApplication.didReceiveMemoryWarningNotification` で `unload()` し「メモリ不足のためモデルを解放しました」を表示。`Memory.cacheLimit` は読み込み時に控えめ（例 64MB）に設定（builder が実機で調整）。
- `GenerateParameters`: temperature 0.7、topP 0.8、maxTokens 512（要約）/ 384（回答）、repetitionPenalty 1.1（筆者判断。実機で調整）。
- 利用可否の理由（`ModelUnavailableReason` を拡張）: シミュレータ、未ダウンロード、読み込み中、空き容量不足、メモリ不足で解放済み、OS 非対応。**MLX は `#if targetEnvironment(simulator)` で完全に迂回**し、CI のシミュレータテストでは「シミュレータでは利用できません」を返す。
- チャット画面の `ModelChoice`（Claude／Apple）は変更しない。日誌の機能は MLX 専用（Claude で日誌を扱う経路は作らない）。

### 画面構成
- ルートを `TabView` にする: 「日誌」（記録 + 一覧 + 検索）／「聞く」／「チャット」（既存の会話一覧をそのまま）。「設定」は従来どおり各タブのツールバーから。既存の「メモ」画面は日誌画面に置き換える（`.noteTool` 由来の項目も日誌に表示する）。
- 音声入力が使えない端末（`SpeechTranscriber.isAvailable == false` または ja-JP 非対応）では録音ボタンを無効にして理由を表示し、テキスト入力だけにする。旧 `SFSpeechRecognizer` への切替はこのフェーズでは作らない（バックログ）。

### CI
- 既存のシミュレータ build/test はそのまま（MLX を含めてコンパイルが通ること）。
- **実機向け無署名ビルド**を追加: `xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`（arm64 で MLX がリンクできる証跡）。
- Codemagic ワークフローは変更なし（手動起動）。

## Phase 2-0 実機ゲート（作り込みの前に必ず通す）
1. AgentRunKitMLX をリンクし、モデル管理画面と検証画面（設定 →「検証」に置き、ゲート後も残す）だけを先に TestFlight へ出す。検証画面の内容: モデルを読み込んで 3 つのサンプル文（短文・300 字・1000 字）を要約／`SpeechTranscriber.isAvailable`・ja-JP 対応・アセット状態の表示と 30 秒の文字起こしテスト。
2. iPhone 15 でユーザーが記録する: ダウンロード時間、読み込み時間、トークン/秒（`GenerateCompletionInfo`）、`Memory.activeMemory` と `os_proc_available_memory()`、要約の日本語品質（主観 3 段階）、メモリ警告の有無、文字起こしの可否と精度の印象。画面に数値を表示し、ユーザーはそれを読み上げるかスクリーンショットで伝える。
3. 結果は Claude がユーザーの報告から `docs/phase2-mlx-eval.md` にまとめ、既定モデルを確定する。品質が足りなければ候補を替える。それでも足りなければ、ユーザーに「聞く機能だけ Claude を使う」選択肢を**提案して承認を得る**（勝手に切り替えない）。
4. **ゲート待ちの間に進めてよい作業**（モデルに依存しない）: 日誌データと `VersionedSchema` 移行、音声入力、Core/Runtime の純粋ロジックと fake による「聞く」パイプライン、画面構成。**モデル固有の調整（プロンプト文言・生成パラメータ・既定モデル）はゲート結果が出てから**確定する。

## テスト（CI で自動化する範囲）
- Core: 相対日付語 → `DateInterval`（境界・該当なし）、検索語 JSON のパースと保険、日誌の詰め込み（件数・文字数・合計上限、新しい順）、要約出力の `見出し:` 解析、空き容量ルール、要約自動実行の閾値（200 文字）、`Note ↔ JournalEntry` 射影。
- Runtime: 台本 `LLMClient`（`generate` に応える fake）で 2 段階パイプライン（正常／JSON 崩れ／0 件で LLM 不呼出／キャンセル）。プロンプトに日誌本文が入り、外部 URL やキーを含まないこと。
- App（シミュレータ）: `JournalEntryRecord` CRUD と日付範囲、Note 移行（1 回だけ・失敗時に元を残す）、`MLXRuntime` の状態遷移を fake ストアで、シミュレータでの可否理由。
- 実機のみ: 文字起こし（長時間・機内モード）、ダウンロード／中断／削除、要約と回答の品質、メモリ警告、AT-02。

## builder に任せること
- ファイル分割、`AVAudioEngine` と `SpeechAnalyzer` の接続詳細、`Progress` の UI、`VersionedSchema` の切り方、`cacheLimit` の実値、見出し解析の細部、Qwen3 の thinking 無効化の可否調査。

## 筆者の判断（レビュー時に見てほしい点）
- 日誌は MLX 専用にし、Claude では扱わない（従量課金回避の意図を優先）。
- 要約の自動実行は 200 文字以上のみ。短い記録はそのまま残す。
- 「聞く」は 2 段階（検索語抽出 → アプリ検索 → 回答）。ツール呼び出しには頼らない。
- 既定モデルは Qwen2.5-1.5B-Instruct-4bit。実機ゲートの結果で差し替え可。
- 増量メモリ entitlement は最初は付けない。
- メモは日誌へ吸収する。ただし Claude のメモツールが読めるのは `save_note` 由来の項目だけ（音声日誌は Claude に渡さない）。
- 「聞く」は日付範囲が母集合、検索語は絞り込みのみ。0 件なら直近 10 件で答える。
- ダウンロードはフォアグラウンドのみ、モバイル回線では確認を出す。
- ルートは 3 タブ（日誌／聞く／チャット）。音声が使えない端末はテキストのみ。
- 実機ゲートは最初の TestFlight で行い、その間はモデル非依存の実装だけ進める。

## 参照
- AgentRunKit 6.1.0 `Sources/AgentRunKitMLX/MLXClient.swift`, `MLXClientTypes.swift`
- mlx-swift-lm 7e19e09 `Libraries/MLXLMCommon/ModelFactory.swift`, `ModelConfiguration.swift`, `ModelContainer.swift`, `Evaluate.swift`
- mlx-swift 6ba4827 `Source/MLX/Memory.swift`, `Package.swift`; MLX issue #2605（シミュレータ非対応）
- Apple: SpeechAnalyzer / SpeechTranscriber / AssetInventory（iOS 26）、`com.apple.developer.kernel.increased-memory-limit`
- Hugging Face: `mlx-community/Qwen2.5-1.5B-Instruct-4bit`, `Qwen/Qwen2.5-1.5B-Instruct`, `mlx-community/Qwen3-1.7B-4bit`, `Qwen/Qwen3-1.7B`
