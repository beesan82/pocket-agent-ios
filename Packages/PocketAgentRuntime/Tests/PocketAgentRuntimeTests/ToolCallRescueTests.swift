import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

private let known: [String: Set<String>] = [
    "save_note": ["text"], "edit_note": ["id", "text"], "search_notes": ["query"], "delete_note": ["id"]
]

struct ToolCallRescueTests {
    @Test func fencedSchemaMatchIsRescued() {
        let text = "あなたの名前をメモとして保存します。\n```json\n{\n  \"text\": \"あなたの名前はケイタ\"\n}\n```\n"
        #expect(ToolCallRescue.extract(from: text, knownTools: known) == .found(RescuedToolCall(
            toolName: "save_note", arguments: #"{"text":"あなたの名前はケイタ"}"#,
            remainingText: "あなたの名前をメモとして保存します。")))
    }

    @Test func namedFormsAreRescued() {
        #expect(ToolCallRescue.extract(
            from: #"{"name":"search_notes","arguments":{"query":"歯医者"}}"#, knownTools: known)
            == .found(RescuedToolCall(toolName: "search_notes", arguments: #"{"query":"歯医者"}"#, remainingText: "")))
        #expect(ToolCallRescue.extract(
            from: #"了解 {"tool":"delete_note","input":{"id":"abc"}}"#, knownTools: known)
            == .found(RescuedToolCall(toolName: "delete_note", arguments: #"{"id":"abc"}"#, remainingText: "了解")))
    }

    @Test func plainTextAndUnknownShapesAreNone() {
        for text in ["こんにちは。", "{}", #"{"foo":"bar"}"#, #"{"name":"finish","arguments":{}}"#,
                     #"{"text": 1}"#, "{ broken"] {
            #expect(ToolCallRescue.extract(from: text, knownTools: known) == .none, Comment(rawValue: text))
        }
    }

    @Test func twoCandidatesAreAmbiguous() {
        let text = #"{"text":"a"} そして {"text":"b"}"#
        #expect(ToolCallRescue.extract(from: text, knownTools: known) == .ambiguous)
    }

    @Test func bracesInsideStringsDoNotBreakScan() {
        let text = #"保存 {"text":"a } b { c"}"#
        #expect(ToolCallRescue.extract(from: text, knownTools: known) == .found(RescuedToolCall(
            toolName: "save_note", arguments: #"{"text":"a } b { c"}"#, remainingText: "保存")))
    }

    @Test func extraKeysDisqualifySchemaMatch() {
        #expect(ToolCallRescue.extract(from: #"{"text":"a","extra":"b"}"#, knownTools: known) == .none)
    }

    @Test func knownToolsComeFromRequiredKeys() {
        let tools = NoteTools.make(store: InMemoryNoteStore(), limit: .claude)
        #expect(ToolCallRescue.knownTools(tools) == [
            "save_note": ["text"], "edit_note": ["id", "text"], "search_notes": ["query"], "delete_note": ["id"]
        ])
    }

    @Test func resultTexts() {
        #expect(ToolCallRescue.resultText(toolName: "save_note", result: .success("{}")) == "メモを保存しました")
        #expect(ToolCallRescue.resultText(toolName: "edit_note", result: .success("{}")) == "メモを更新しました")
        #expect(ToolCallRescue.resultText(toolName: "delete_note", result: .success("{}")) == "メモを削除しました")
        #expect(ToolCallRescue.resultText(
            toolName: "search_notes",
            result: .success(#"{"notes":[{"id":"1","createdAt":"x","kind":"note","text":"歯医者"}],"truncated":false}"#))
            == "- 歯医者")
        #expect(ToolCallRescue.resultText(
            toolName: "search_notes", result: .success(#"{"notes":[],"truncated":false}"#))
            == "該当するメモがありません")
        #expect(ToolCallRescue.resultText(
            toolName: "save_note", result: .error("メモは1〜2000文字で指定してください"))
            == "メモは1〜2000文字で指定してください")
    }
}
