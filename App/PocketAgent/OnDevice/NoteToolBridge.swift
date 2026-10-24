import AgentRunKit
import Foundation

/// Runs a note tool by name with JSON arguments: the Foundation Models tools (`FMNoteTools`) call
/// the same gated, recorded `NoteTools` the Claude path uses, so validation, limits and approval
/// live in one place.
enum NoteToolBridge {
    /// The tool's result text, errors included (the model reads why it failed). Cancellation
    /// (the user stopped the turn while the approval sheet was open) is rethrown.
    static func invoke(
        _ name: String, argumentsJSON: String, tools: [any AnyTool<EmptyContext>]
    ) async throws -> String {
        guard let tool = tools.first(where: { $0.name == name }) else { return "Unknown tool: \(name)" }
        let result = try await tool.execute(arguments: Data(argumentsJSON.utf8), context: EmptyContext())
        return result.content
    }

    static func json(_ value: some Encodable) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "{}"
    }
}
