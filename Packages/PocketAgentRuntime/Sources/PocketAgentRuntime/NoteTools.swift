import AgentRunKit
import Foundation
import PocketAgentCore

public struct NoteResultLimit: Sendable {
    public let maxNotes: Int
    public let maxCharactersPerNote: Int?

    public init(maxNotes: Int, maxCharactersPerNote: Int?) {
        self.maxNotes = maxNotes
        self.maxCharactersPerNote = maxCharactersPerNote
    }

    public static let claude = NoteResultLimit(maxNotes: 50, maxCharactersPerNote: nil)
    public static let appleLocal = NoteResultLimit(maxNotes: 10, maxCharactersPerNote: 200)
}

public enum NoteToolName {
    public static let save = "save_note"
    public static let list = "list_notes"
    public static let search = "search_notes"
    public static let delete = "delete_note"
}

/// The agent's memory tools.
///
/// These implement `AnyTool` directly instead of using `Tool<P, O, C>`: validation and
/// store failures are returned as `ToolResult.error` and never thrown, because
/// `FoundationModelsClient` turns a thrown tool error into a failed session.
/// Only `CancellationError` propagates.
public enum NoteTools {
    public static let maxNoteLength = 2000

    public static func make(store: any NoteStore, limit: NoteResultLimit) -> [RegisteredTool<EmptyContext>] {
        [
            RegisteredTool(NoteTool(
                name: NoteToolName.save,
                description: "ユーザーが覚えておいてと頼んだ内容・予定・用事をメモとして保存する。"
                    + "保存前にユーザーの承認が必要。1〜\(maxNoteLength)文字。",
                schema: SaveNoteArgs.jsonSchema,
                isReadOnly: false
            ) { arguments in
                guard let args = decode(SaveNoteArgs.self, arguments) else { return invalidArguments }
                let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1 ... maxNoteLength).contains(text.count) else {
                    return .error("メモは1〜\(maxNoteLength)文字で指定してください")
                }
                return try await guarded("メモを保存できませんでした") {
                    let note = try await store.add(text)
                    return try encode(SavedNote(id: note.id.uuidString, text: note.text))
                }
            }, risk: .appInternalWrite),
            RegisteredTool(NoteTool(
                name: NoteToolName.list,
                description: "保存済みのメモを新しい順に一覧する。",
                schema: ListNotesArgs.jsonSchema,
                isReadOnly: true
            ) { _ in
                try await guarded("メモを読み込めませんでした") {
                    try encodeList(try await store.all(), limit: limit)
                }
            }, risk: .readOnly),
            RegisteredTool(NoteTool(
                name: NoteToolName.search,
                description: "保存済みのメモをキーワードで検索する。空白区切りの語をすべて含むメモを新しい順に返す。",
                schema: SearchNotesArgs.jsonSchema,
                isReadOnly: true
            ) { arguments in
                guard let args = decode(SearchNotesArgs.self, arguments) else { return invalidArguments }
                return try await guarded("メモを検索できませんでした") {
                    try encodeList(try await store.search(args.query), limit: limit)
                }
            }, risk: .readOnly),
            RegisteredTool(NoteTool(
                name: NoteToolName.delete,
                description: "メモを1件削除する。list_notes または search_notes で得た id を指定する。毎回ユーザーの承認が必要。",
                schema: DeleteNoteArgs.jsonSchema,
                isReadOnly: false
            ) { arguments in
                guard let args = decode(DeleteNoteArgs.self, arguments),
                      let id = UUID(uuidString: args.id)
                else { return invalidArguments }
                return try await guarded("メモを削除できませんでした") {
                    guard try await store.delete(id: id) else {
                        return .error("該当するメモがありません")
                    }
                    return try encode(DeleteResult(deleted: true))
                }
            }, risk: .appInternalDelete)
        ]
    }

    // MARK: - Helpers

    private static let invalidArguments = ToolResult.error("引数が正しくありません")

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// Runs `body`, mapping any non-cancellation failure to a fixed message.
    private static func guarded(
        _ failure: String,
        _ body: () async throws -> ToolResult
    ) async throws -> ToolResult {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error(failure)
        }
    }

    private static func encode(_ value: some Encodable) throws -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return .success(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func encodeList(_ notes: [Note], limit: NoteResultLimit) throws -> ToolResult {
        let kept = notes.prefix(max(0, limit.maxNotes))
        var truncated = kept.count < notes.count
        let items = kept.map { note -> NoteItem in
            var text = note.text
            if let maxCharacters = limit.maxCharactersPerNote, text.count > maxCharacters {
                text = String(text.prefix(maxCharacters))
                truncated = true
            }
            return NoteItem(id: note.id.uuidString, createdAt: note.createdAt, text: text)
        }
        return try encode(NoteList(notes: items, truncated: truncated))
    }
}

private struct NoteTool: AnyTool {
    typealias Context = EmptyContext

    let name: String
    let description: String
    let parametersSchema: JSONSchema
    let isReadOnly: Bool
    let run: @Sendable (Data) async throws -> ToolResult

    init(
        name: String,
        description: String,
        schema: JSONSchema,
        isReadOnly: Bool,
        run: @escaping @Sendable (Data) async throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        parametersSchema = schema
        self.isReadOnly = isReadOnly
        self.run = run
    }

    func execute(arguments: Data, context _: EmptyContext) async throws -> ToolResult {
        try await run(arguments)
    }
}

private struct SaveNoteArgs: Codable, SchemaProviding {
    let text: String
}

private struct ListNotesArgs: Codable, SchemaProviding {
    static var jsonSchema: JSONSchema { .object(properties: [:], required: []) }
}

private struct SearchNotesArgs: Codable, SchemaProviding {
    let query: String
}

private struct DeleteNoteArgs: Codable, SchemaProviding {
    let id: String
}

private struct SavedNote: Encodable {
    let id: String
    let text: String
}

private struct NoteItem: Encodable {
    let id: String
    let createdAt: Date
    let text: String
}

private struct NoteList: Encodable {
    let notes: [NoteItem]
    let truncated: Bool
}

private struct DeleteResult: Encodable {
    let deleted: Bool
}
