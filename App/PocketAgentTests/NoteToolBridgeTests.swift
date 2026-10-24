import AgentRunKit
import Foundation
import PocketAgentCore
import PocketAgentRuntime
import Testing
@testable import PocketAgent

/// The Foundation Models note tools call the same NoteTools (validation, limits, approval gate)
/// through this bridge; the FM types themselves need a real model and are not unit-tested.
struct NoteToolBridgeTests {
    private func plainTools(_ store: InMemoryNoteStore) -> [any AnyTool<EmptyContext>] {
        NoteTools.make(store: store, limit: .appleLocal).map(\.tool)
    }

    @Test func invokeSaveStoresNote() async throws {
        let store = InMemoryNoteStore()
        let result = try await NoteToolBridge.invoke(
            "save_note", argumentsJSON: #"{"text":"牛乳"}"#, tools: plainTools(store))

        #expect(try await store.all().map(\.text) == ["牛乳"])
        #expect(result.contains("牛乳"))
    }

    @Test func invokeReturnsErrorContent() async throws {
        let store = InMemoryNoteStore()
        let result = try await NoteToolBridge.invoke(
            "edit_note", argumentsJSON: #"{"id":"not-a-uuid","text":"x"}"#, tools: plainTools(store))

        #expect(result == "引数が正しくありません")
    }

    @Test func invokeUnknownTool() async throws {
        let result = try await NoteToolBridge.invoke("nope", argumentsJSON: "{}", tools: [])
        #expect(result == "Unknown tool: nope")
    }

    @Test func invokeThroughGateDeniedDoesNotSave() async throws {
        let store = InMemoryNoteStore()
        let gated = ToolApprovalGate.wrap(
            NoteTools.make(store: store, limit: .appleLocal), approval: { _ in .deny(reason: nil) })

        let result = try await NoteToolBridge.invoke("save_note", argumentsJSON: #"{"text":"牛乳"}"#, tools: gated)

        #expect(try await store.all().isEmpty)
        #expect(result.hasPrefix("Tool call denied by user"))
    }
}
