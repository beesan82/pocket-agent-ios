# 計画: 二言語経路への用語辞書の適用（ADR-048）

設計: `docs/superpowers/specs/2026-11-09-bilingual-term-dictionary-design.md`

- [ ] Task 1（RED）: `App/PocketAgentTests/BilingualTermCorrectionTests.swift` を追加し、一時ブランチ＋一時 PR で CI がアプリ単体テストで失敗することを確認する。確認後は一時ブランチと一時 PR を片付ける。
- [ ] Task 2（GREEN）: `MeetingSession.segmentText(for:)` を追加し、`accept(_:)` のセグメント生成で使う（ja の受理候補のみ `SpeechCapture.correctFinalText` を適用）。`SpeechCapture.correctFinalText` のコメントを実態に合わせる。
- [ ] Task 3（記録）: ADR-048 を `docs/decisions.md` に追記し、`docs/phase0-checklist.md` の「専門用語対策 実験2」節に二言語適用を実装済みとして足し、未検証項目を実機確認項目へ更新する。
- [ ] Task 4（検証）: PR の CI 全ステップ成功を確認してからマージする。`main` の CI はマージ後に確認する。
- [ ] Task 5（実機、人の作業）: TestFlight 配信後、iPhone 15 の二言語会議で日本語の専門用語が補正されること・英語発話が無変更なことを確認し、結果をチェックリストへ記録する。
