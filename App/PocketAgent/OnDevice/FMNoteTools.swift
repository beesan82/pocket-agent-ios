import AgentRunKit
import Foundation
import FoundationModels
import PocketAgentRuntime

/// The five note tools as Foundation Models tools. Each one only carries typed arguments and
/// forwards them as JSON to the matching (gated, recorded) `NoteTools` tool via `NoteToolBridge`.
enum FMNoteTools {
    static func make(_ tools: [any AnyTool<EmptyContext>]) -> [any FoundationModels.Tool] {
        tools.compactMap { tool -> (any FoundationModels.Tool)? in
            let base = FMToolBase(name: tool.name, description: tool.description, tools: tools)
            switch tool.name {
            case NoteToolName.save: return SaveNoteFMTool(base: base)
            case NoteToolName.edit: return EditNoteFMTool(base: base)
            case NoteToolName.list: return ListNotesFMTool(base: base)
            case NoteToolName.search: return SearchNotesFMTool(base: base)
            case NoteToolName.delete: return DeleteNoteFMTool(base: base)
            default: return nil
            }
        }
    }
}

struct FMToolBase: Sendable {
    let name: String
    let description: String
    let tools: [any AnyTool<EmptyContext>]

    func invoke(_ arguments: some Encodable) async throws -> String {
        try await NoteToolBridge.invoke(name, argumentsJSON: NoteToolBridge.json(arguments), tools: tools)
    }
}

struct SaveNoteFMTool: FoundationModels.Tool {
    let base: FMToolBase
    var name: String { base.name }
    var description: String { base.description }

    @Generable
    struct Arguments {
        @Guide(description: "保存するメモの本文")
        var text: String
    }

    private struct JSON: Encodable { let text: String }

    func call(arguments: Arguments) async throws -> String {
        try await base.invoke(JSON(text: arguments.text))
    }
}

struct EditNoteFMTool: FoundationModels.Tool {
    let base: FMToolBase
    var name: String { base.name }
    var description: String { base.description }

    @Generable
    struct Arguments {
        @Guide(description: "書き換えるメモの id（list_notes / search_notes の結果の id）")
        var id: String
        @Guide(description: "新しい本文")
        var text: String
    }

    private struct JSON: Encodable { let id: String; let text: String }

    func call(arguments: Arguments) async throws -> String {
        try await base.invoke(JSON(id: arguments.id, text: arguments.text))
    }
}

struct ListNotesFMTool: FoundationModels.Tool {
    let base: FMToolBase
    var name: String { base.name }
    var description: String { base.description }

    @Generable
    struct Arguments {}

    private struct JSON: Encodable {}

    func call(arguments _: Arguments) async throws -> String {
        try await base.invoke(JSON())
    }
}

struct SearchNotesFMTool: FoundationModels.Tool {
    let base: FMToolBase
    var name: String { base.name }
    var description: String { base.description }

    @Generable
    struct Arguments {
        @Guide(description: "検索する語（空白区切りの語をすべて含むメモを探す）")
        var query: String
    }

    private struct JSON: Encodable { let query: String }

    func call(arguments: Arguments) async throws -> String {
        try await base.invoke(JSON(query: arguments.query))
    }
}

struct DeleteNoteFMTool: FoundationModels.Tool {
    let base: FMToolBase
    var name: String { base.name }
    var description: String { base.description }

    @Generable
    struct Arguments {
        @Guide(description: "削除するメモの id（list_notes / search_notes の結果の id）")
        var id: String
    }

    private struct JSON: Encodable { let id: String }

    func call(arguments: Arguments) async throws -> String {
        try await base.invoke(JSON(id: arguments.id))
    }
}
