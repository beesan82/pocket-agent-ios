# CER 数字表記正規化の実装計画（2026-11-04）

設計書: `docs/superpowers/specs/2026-11-04-cer-numeral-normalization-design.md`
決定: ADR-046（物差しの定義変更と系列分離）

## Task 1: Swift テストで新ルールを固定する（RED）

- [x] Step 1: `TranscriptionScorerTests` に数字変換のテストを足す。変換例（三千→3000、二千二十八→2028、千二百→1200、三千億と 3000億 の一致、午前十時と午前10時の一致、一部と1部の一致、二〇二八→2028、一万二千→12000）、数字を含まない文が不変であること、解釈できない表記（単独の億・万、規則違反の連続）が不変であること、固定文 A〜C の再採点値（Python 実装と突き合わせた値）。
- [x] Step 2: 既存テスト `fullWidthDigitsAreNormalizedBeforeScoring`（表記ゆれを誤りとして数える旧ルールの固定）を、新ルールの期待値（CER 0）へ書き換える。
- [x] Step 3: ブランチ `feat/cer-numeral-normalization` を push して PR を開き、CI が新しいテストで失敗すること（RED）を確認する。`main` には失敗コミットを入れない。

## Task 2: 実装（Swift と Python を同一ルールで）

- [x] Step 1: Core の `TranscriptionScorer.normalize` の最終段に数字表記の変換を実装する（設計書の変換仕様どおり）。
- [x] Step 2: `tools/cer.py` に同じ変換を実装し、`--keep-numerals`（旧系列の再現用）を足す。`tools/test_cer.py` を作り、Swift テストと同一の変換ケースを流して両実装の一致を確かめる。
- [x] Step 3: 初回ベースラインの認識テキスト（2026-11-04 の実機結果）を新しい `tools/cer.py` で再採点し、新系列の参考値としてベースライン文書（`docs/verification/2026-11-03-transcription-accuracy-baseline.md`）へ旧系列と並記で追記する。未決課題の節は ADR-046 で決定済みに更新する。
- [x] Step 4: `docs/decisions.md` に ADR-046 を追記する（定義変更、系列分離、RED/GREEN の run ID）。
- [ ] Step 5: PR の CI が全グリーンになることを確認する。マージは所有者の判断を待つ。
