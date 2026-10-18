# Decisions (ADR)

各項目: 決定 / 理由 / 影響要件 / 状態。

## ADR-001 プロジェクト生成に XcodeGen を採用
- 決定: `project.yml` から CI 上で `.xcodeproj` を生成し、`.xcodeproj` はコミットしない。
- 理由: Windows で pbxproj を手編集するのは事実上不可能。YAML なら差分レビューも容易（要件3.1「プロジェクト生成」）。
- リスク: CI の `brew install xcodegen` はバージョン非固定。問題が出たら mint 等でピン留めする。
- 状態: 採用（CI 未実行）

## ADR-002 AgentRunKit を exact 6.1.0 に固定
- 決定: `exactVersion: 6.1.0`。tag `v6.1.0` の commit は `a7ac823ca42d4ecff386a83c10a44a97bd391cdb`（2026-10-18 GitHub API で確認）。
- 理由: 要件13章「API変更／不安定さ」対策。`from:` では意図しない更新が入る。
- 状態: 採用（CI で Package.resolved を生成後、その内容をコミットして確定させる）

## ADR-003 ドメインを AgentRunKit 非依存の Swift Package に分離
- 決定: `Packages/PocketAgentCore` は Foundation のみに依存。AgentRunKit 呼び出しは `App/PocketAgent/Adapters` に限定。
- 理由: 要件3.3 設計原則、14章-3。SDK 交換時（代替案「薄い独自 Runtime」）の影響範囲を限定。
- 状態: 採用

## ADR-004 LINE 共有 URL は RFC 3986 unreserved 以外をすべて percent-encode
- 決定: `https://line.me/R/share?text=` の値を `A-Z a-z 0-9 - . _ ~` 以外すべてエンコードし、`URLComponents.percentEncodedQueryItems` に設定する。
- 理由: `URLComponents.queryItems` は `+` などをエンコードしないため、受信側で空白に化ける可能性がある（要件9.1、AT-06）。
- 状態: 実装済み・ユニットテストあり（CI 未実行）

## ADR-005 最低 OS は iOS 26.0
- 決定: deployment target iOS 26.0（要件3.2）。AgentRunKit 自体は iOS 18+ だが FoundationModelsClient は iOS 26+。
- 状態: 採用

## ADR-006 CI runner は `macos-26`、Xcode は 26.x の最新を選択
- 決定: runner image に同梱の `/Applications/Xcode_26*.app` から最新を `xcode-select` する。
- 理由: AgentRunKit v6.1.0 は Xcode 26+ 必須。runner の Xcode 構成は変わるため、ログに実際の版を出力して証跡にする。
- 状態: 採用（未実行。Xcode 26 が見つからなければ CI が明示的に失敗する）

## 未決定
- 永続化: SwiftData 優先（要件15章）。Phase 1 冒頭で決定。
- Bundle ID / Team ID: 未定。現在はプレースホルダ `com.example.pocketagent`。
