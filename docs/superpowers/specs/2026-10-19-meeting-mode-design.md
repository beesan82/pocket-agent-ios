# 会議モード設計: リアルタイム文字起こしと随時の要点更新（端末内）

日付: 2026-10-19 / 対象要件: FR-11, FR-14, FR-15、要件 6.3（ローカルプライバシー）、AT-02（端末内）
前提: Phase 2（MLX 日誌・聞く・タブ構成）がコミット済み（8ab615c）。実機は iPhone 15。
位置づけ: ユーザーの「たたき台をえいやで作って、使いながら調整する」という指示に基づく **初版**。設計上の選択はすべて作り手（Claude）の判断であり、使ってみた結果で変える前提。

## 意図（ユーザーの言葉から）
- 「リアルタイム文字おこし機能を搭載したい。次ステップには同時翻訳も考えている」
- 「会議中につかいながら要点をまとめさせたりしたい。リアルでのミーティングを想定」
- 要点は「随時」更新。
- 「現状はローカル前提でいい」（音声も文字も端末の外へ出さない）。
- iPhone はポケットやロック状態でも録音を続ける（画面を点けっぱなしにしない）。
- 要点の形式は未指定 → 作り手の初期案で始め、使いながら調整。

## ゴール
- G1 会議中、iPhone のマイク音声を **端末内** で日本語に文字起こしし、画面に流す（確定文は濃く、仮文は薄く）。
- G2 文字起こしがたまるごとに、端末内 LLM（MLX・既定 Qwen2.5 1.5B）が **要点を差分更新** する。手動の「今すぐ更新」もある。
- G3 ロック中・バックグラウンドでも録音と文字起こしが止まらない。
- G4 終了時に **全文（時刻付き）と要点を日誌 1 件** として保存し、既存の「聞く」から検索できる。
- G5 次ステップの同時翻訳に備え、文字起こしを **発言のまとまり（セグメント）** 単位で持つ。

## 非ゴール（今回やらない）
- 翻訳（次ステップ。セグメント単位の設計だけ用意する）。
- 話者分離、音声ファイルの保存、Claude への送信、日本語以外の文字起こし。
- バックグラウンドでの要点更新（MLX は Metal を使うため、アプリが前面にない間は実行できない）。
- ロック画面ウィジェット／Live Activity／Now Playing 表示。

## アンチゴール（動いても失敗）
- 会議の音声や文字が外部へ送られる。
- モデルが無い・要約に失敗した状態で、文字起こしの全文が保存できない（全文保存は常に可能）。
- 画面を離れたりロックしたりしただけで録音が止まる、または録音中にタブを切り替えると状態が消える。
- 要点更新の最中に文字起こしが止まる（UI がブロックされる）。
- メモリ警告で落ちる（既存どおりモデルを解放し、文字起こしは続ける）。

## 事実確認（設計の根拠）
- `SpeechCapture`（App/PocketAgent/Speech）は iOS 26 の `SpeechAnalyzer` + `SpeechTranscriber(preset: .progressiveTranscription)` を日本語・端末内で動かし、確定文 `finalText` と仮文 `volatileText` を出す。iPhone 15 で動作確認済み（docs/phase2-mlx-eval.md）。旧 SFSpeechRecognizer の約 1 分制限はない。
- `JournalAssistant.summarize` は MLX クライアントの `stream` を使い、1.5B で 1 回 3〜12 秒（iPhone 15 実測）。
- バックグラウンド録音は Info.plist の `UIBackgroundModes` に `audio` を入れ、`AVAudioSession` を `.record` で有効化していれば継続する（Apple の標準的な仕組み。SpeechAnalyzer がロック中も動き続けることは **実機で未検証**）。
- MLX（Metal）はアプリがバックグラウンドにいる間 GPU を使えない → 要点更新は前面のときだけ。
- `UIApplication.didReceiveMemoryWarningNotification` で `MLXRuntime` がモデルを解放する既存挙動がある。

## 画面（タブ「会議」）
タブを 1 つ増やす: 日誌 / 聞く / **会議** / チャット。会議の状態はアプリ全体で 1 つ（`MeetingSession` をアプリが保持）なので、タブを離れても録音は続く。

- **待機中**: 大きな「会議を開始」ボタン。音声入力が使えない理由（権限・アセット未導入）があれば既存と同じ文言と導線（「音声データを入手」「マイクと音声認識を許可」）。モデルの状態は既存の `JournalModelStatusView` を流用（モデルが無くても開始はできる。要点が付かないだけ）。
- **録音中**（上から）:
  1. 経過時間、録音中インジケータ、「終了」ボタン。
  2. **要点カード**: 現在の要点（下記の形式）。右上に「更新」ボタンと「未反映 ○文字」の小さな表示。更新中はプログレス表示と「停止」。失敗時は「要点を更新できませんでした（前回の要点を表示中）」。モデル未準備なら「要点はモデルを読み込むと付きます」+ 読み込み導線。
  3. **文字起こし**: セグメントの一覧（時刻 `mm:ss` + 本文）。末尾に仮文を薄い色で。新しいものが来たら末尾へ自動スクロール（ユーザーが上へスクロールしている間は追従しない）。
- **終了後**: 「保存しました」と日誌タブへの導線、または失敗文言と「もう一度保存」。保存前に「破棄」確認は出さない（終了＝保存。保存に失敗したら全文は画面に残り再試行できる）。

## 動き
### セグメント
`TranscriptSegment { id: UUID, offset: TimeInterval（録音開始からの秒）, text: String }`。`SpeechTranscriber` の確定結果 1 件 = 1 セグメント。`offset` は結果の `range.start`（取れなければ受信時刻 − 開始時刻）。翻訳の次ステップでは `translation: String?` を足すだけで済ませる。

### 要点の差分更新
- 入力: **前回の要点（本文）** + **前回以降に確定したセグメントの本文**。出力: 更新後の要点の全文（置き換え）。
- 自動更新の条件（`MeetingNotesPolicy.shouldUpdate`）: アプリが前面 **かつ** モデルが使える **かつ** 更新が走っていない **かつ** 未反映の確定文が **300 文字以上** **かつ** 前回更新開始から **60 秒以上**。前回が無い（初回）ときは文字数条件だけ。
- 手動「更新」: 未反映が 1 文字以上あれば条件を無視して実行。
- 前面に戻ったとき（scenePhase が active になったとき）: 条件を満たせば即実行（ロック中の分を追いつく）。
- 更新中に新しい確定文が来たら、それは次回の未反映に回す（更新開始時点で「どこまで反映したか」を記録する）。
- 失敗（モデルエラー・解放）: 前回の要点を保持し、未反映は減らさない。文言を出す。
- 停止ボタン: ストリームを切り、**部分出力は捨てて前回の要点を保持**（途中の箇条書きは信用できないため）。
- 終了時: 未反映が残っていて前面かつモデルが使えるなら最後に 1 回更新してから保存（最大 1 回、ユーザーは「停止」で飛ばせる）。

### 要点の形式（初版・作り手の案）
```
## 決まったこと
- …
## 宿題
- 〇〇（担当: △△、期限: …）
## 論点・未決
- …
```
プロンプト（`MeetingPrompts.notesSystem`）の要旨: 「あなたは会議の書記。前回の要点と新しい発言から、要点を更新して全文を出力。見出しは上記 3 つ固定、各見出し最大 7 項目、固有名詞・数字・日時は落とさない、発言に無いことは書かない、前置き・説明は書かない」。`max_tokens` 512、その他は `JournalAssistant.context` と同じ。1.5B の品質は **実機で見てから** 調整する（プロンプト文言と閾値は定数にまとめ、変えやすくする）。

### 保存
- `NewJournalEntry(source: .voice, origin: .journal, body: 要点（無ければ全文）, transcript: 全文, title: "会議 M/d HH:mm")`。
- 全文の形: 各行 `[mm:ss] 本文`（`MeetingTranscriptFormatter.text(segments)`）。
- 要点が空（モデル未使用）なら `body = 全文, transcript = nil`（既存の捕捉画面と同じ規則）。
- セグメントが 0 件で終了したら保存せず「音声を認識できませんでした」。

### バックグラウンド・中断
- `project.yml` の app target に `INFOPLIST_KEY_UIBackgroundModes: audio`（xcodegen の Info 生成に乗せる。生成できない場合は `info` セクションでキーを直接書く）。
- `AVAudioSession.interruptionNotification`: 中断開始で録音を一時停止状態（`paused`）にし表示する。中断終了で `shouldResume` なら文字起こしを再開（パイプラインを作り直す。セグメントは `MeetingSession` が持つので消えない）。再開できなければ `paused` のまま「録音が中断されました。再開してください」とボタンを出す。
- `AVAudioSession.routeChangeNotification`（イヤホン抜き差し）は初版では無視。
- 音声アセットが途中で消える／結果ストリームが失敗した場合: 既存 `SpeechCapture` の失敗処理に合わせ `paused` + 文言。これまでのセグメントは保持、終了して保存できる。

### 長時間
- 1 時間級の連続入力で SpeechAnalyzer とメモリがどうなるかは **未検証**。初版では対策せず、実機で測って `docs/phase2-mlx-eval.md` に追記する（必要なら N 分ごとにパイプラインを作り直す案）。
- 画面のセグメント一覧は `LazyVStack`。モデルへ渡すのは差分なので全文長に依存しない。

## 構成（どこに何を置くか）
- **Core**（純粋・テスト容易）: `MeetingTranscript.swift` に `TranscriptSegment`、`MeetingTranscriptFormatter`（`mm:ss` 整形、全文整形）、`MeetingNotesPolicy`（更新条件と閾値定数）、`MeetingTitle.make(start:)`.
- **Runtime**: `JournalAssisting` に `updateMeetingNotes(previous: String, newText: String) -> AsyncThrowingStream<String, Error>` を追加。`JournalAssistant` が `MeetingPrompts` で実装（`contentOnly` を再利用）。
- **App**:
  - `Speech/SpeechCapture.swift`: 確定結果ごとに `TranscriptSegment` を流す `events: AsyncStream<TranscriptEvent>`（`.volatile(String)`, `.final(TranscriptSegment)`, `.failed(String)`）を追加。既存の `finalText`/`volatileText` は残す。`protocol TranscriptSource`（`start`/`stop`/`events`/`reason`）を切り、テストでは偽物を入れる。
  - `Meeting/MeetingSession.swift`（`@MainActor @Observable`）: 状態 `idle / preparing / recording / paused(String) / finishing / saved / failed(String)`、`segments`、`volatileText`、`notes`、`notesPhase`（`idle / updating / failed(String)`）、`pendingCharacters`、`isForeground`、`elapsed`。操作: `start()`, `stop()`（終了して保存）, `updateNotesNow()`, `stopNotesUpdate()`, `resume()`, `setForeground(Bool)`, `setAssistant(_:)`。
  - `Views/MeetingView.swift`、`RootTabView` にタブ追加、`PocketAgentApp` で `MeetingSession` を 1 つ生成して渡す。`scenePhase` を `MeetingView` ではなく `ContentView` で監視して `setForeground` を呼ぶ（タブを離れても反映されるように）。
  - `MeetingSession` が `JournalModelAccess.client` でモデルを得る（録音開始時にダウンロード済みなら読み込む。未ダウンロードなら要点なし）。

## テスト（CI・シミュレータ）
- Core: `MeetingTranscriptFormatterTests`（`mm:ss`、1 時間超は `h:mm:ss`、全文整形）、`MeetingNotesPolicyTests`（各条件の真偽、初回は時間条件なし、手動は文字数 1 以上のみ）、`MeetingTitleTests`。
- Runtime: `JournalAssistantTests` に `updateMeetingNotesSendsPreviousAndNew`（プロンプトに前回と新規の両方が入る、`contentOnly` で本文だけ）。
- App（`MeetingSessionTests`、偽 `TranscriptSource` と `FakeJournalAssistant` 拡張）: `finalSegmentsAppendAndCountPending`, `autoUpdateWaitsForThresholdAndForeground`, `becomingForegroundCatchesUp`, `manualUpdateIgnoresThreshold`, `segmentsArrivingDuringUpdateStayPending`, `failedUpdateKeepsPreviousNotes`, `stopUpdateDiscardsPartial`, `stopSavesNotesAndTimestampedTranscript`, `stopWithoutModelSavesTranscriptOnly`, `stopWithNoSegmentsDoesNotSave`, `sourceFailureBecomesPausedAndKeepsSegments`.
- 実機で確認すること（CI では無理）: ロック中の継続、電話割り込み後の再開、1 時間連続、要点の品質と閾値の妥当性、録音中のモデル読み込みでメモリ警告が出ないか。

## 作り手に委ねること
- 要点カードと文字起こし一覧の細かな見た目、自動スクロールの実装。
- `SpeechTranscriber` の結果から `range` を取る方法（取れなければ受信時刻で代替）。
- 更新中インジケータの文言。

## 次ステップ（別途設計）
- 同時翻訳: 確定セグメントごとに iOS 26 の Translation フレームワーク（端末内）で翻訳し、セグメントの下に併記。翻訳先言語の設定、翻訳アセットのダウンロード導線。
- 要点形式のユーザー調整（テンプレート選択）。
