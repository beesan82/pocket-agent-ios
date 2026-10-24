import AgentRunKit
import Foundation

/// Set by `ChatSession.stop()` for one on-device turn. Foundation Models may run a tool call
/// outside the task the chat cancels, so the stop is carried to the tools explicitly.
final class TurnStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() { lock.withLock { stopped = true } }
}

/// Refuses to run once the turn is stopped, before the approval sheet is shown and again before
/// the tool runs, whatever the framework does with cancellation (AT-08).
struct StoppableTool: AnyTool {
    typealias Context = EmptyContext

    let inner: any AnyTool<EmptyContext>
    let turnStop: TurnStop

    var name: String { inner.name }
    var description: String { inner.description }
    var parametersSchema: JSONSchema { inner.parametersSchema }
    var isConcurrencySafe: Bool { inner.isConcurrencySafe }
    var isReadOnly: Bool { inner.isReadOnly }
    var maxResultCharacters: Int? { inner.maxResultCharacters }
    var toolTimeout: Duration? { inner.toolTimeout }
    var strict: Bool? { inner.strict }

    func execute(arguments: Data, context: EmptyContext) async throws -> ToolResult {
        guard !turnStop.isStopped else { throw CancellationError() }
        return try await inner.execute(arguments: arguments, context: context)
    }
}
