import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

// FoundationModelsClient calls `execute` on its tools directly (ADR-009).
// These tests do the same, so they cover the on-device path without the device.

private let rawArgs = Data(#"{"text":"10分遅れます"}"#.utf8)

private func makeTool(_ name: String, executions: Log<String>) throws -> any AnyTool<EmptyContext> {
    try Tool<TextParams, String, EmptyContext>(name: name, description: "test tool \(name)") { params, _ in
        await executions.append(params.text)
        return "ok"
    }
}

private func gated(
    _ name: String,
    risk: ToolRisk,
    executions: Log<String>,
    approvals: Log<PendingApproval>,
    decision: UserApprovalDecision
) throws -> any AnyTool<EmptyContext> {
    let tools = try ToolApprovalGate.wrap(
        [RegisteredTool(makeTool(name, executions: executions), risk: risk)]
    ) { request in
        await approvals.append(request)
        return decision
    }
    return try #require(tools.first)
}

struct ApprovalGatedToolTests {
    @Test func readOnlyToolRunsWithoutAsking() async throws {
        let executions = Log<String>(), approvals = Log<PendingApproval>()
        let tool = try gated("read_input", risk: .readOnly, executions: executions, approvals: approvals,
                             decision: .deny(reason: nil))

        let result = try await tool.execute(arguments: rawArgs, context: EmptyContext())

        #expect(!result.isError)
        #expect(await executions.entries == ["10分遅れます"])
        #expect(await approvals.entries.isEmpty)
    }

    // AT-05 on the on-device path: denial means the tool body never runs.
    @Test func deniedSideEffectToolIsNeverExecuted() async throws {
        let executions = Log<String>(), approvals = Log<PendingApproval>()
        let tool = try gated("open_line_share", risk: .externalSideEffect, executions: executions,
                             approvals: approvals, decision: .deny(reason: "やめる"))

        let result = try await tool.execute(arguments: rawArgs, context: EmptyContext())

        #expect(result.isError)
        #expect(result.content.contains("denied"))
        #expect(result.content.contains("やめる"))
        #expect(await executions.entries.isEmpty)
        let requests = await approvals.entries
        #expect(requests.count == 1)
        #expect(requests.first?.toolName == "open_line_share")
        #expect(requests.first?.risk == .externalSideEffect)
        #expect(requests.first?.arguments == #"{"text":"10分遅れます"}"#)
    }

    @Test func approvedSideEffectToolRunsOnce() async throws {
        let executions = Log<String>(), approvals = Log<PendingApproval>()
        let tool = try gated("open_line_share", risk: .externalSideEffect, executions: executions,
                             approvals: approvals, decision: .approveOnce)

        let result = try await tool.execute(arguments: rawArgs, context: EmptyContext())

        #expect(!result.isError)
        #expect(await executions.entries == ["10分遅れます"])
    }

    // Duplicate-share guard, same rule as AgentRunner.
    @Test func sessionApprovalIsDowngradedForExternalSideEffects() async throws {
        let executions = Log<String>(), approvals = Log<PendingApproval>()
        let tool = try gated("open_line_share", risk: .externalSideEffect, executions: executions,
                             approvals: approvals, decision: .approveForSession)

        _ = try await tool.execute(arguments: rawArgs, context: EmptyContext())
        _ = try await tool.execute(arguments: rawArgs, context: EmptyContext())

        #expect(await approvals.entries.count == 2)
        #expect(await executions.entries.count == 2)
    }

    @Test func sessionApprovalIsHonouredForAppInternalWrites() async throws {
        let executions = Log<String>(), approvals = Log<PendingApproval>()
        let tool = try gated("save_note", risk: .appInternalWrite, executions: executions,
                             approvals: approvals, decision: .approveForSession)

        _ = try await tool.execute(arguments: rawArgs, context: EmptyContext())
        _ = try await tool.execute(arguments: rawArgs, context: EmptyContext())

        #expect(await approvals.entries.count == 1)
        #expect(await executions.entries.count == 2)
    }

    // Session approval is per gate() call, i.e. per conversation, not global.
    @Test func sessionApprovalDoesNotLeakAcrossGates() async throws {
        let executions = Log<String>(), approvals = Log<PendingApproval>()
        let first = try gated("save_note", risk: .appInternalWrite, executions: executions,
                              approvals: approvals, decision: .approveForSession)
        let second = try gated("save_note", risk: .appInternalWrite, executions: executions,
                               approvals: approvals, decision: .approveForSession)

        _ = try await first.execute(arguments: rawArgs, context: EmptyContext())
        _ = try await second.execute(arguments: rawArgs, context: EmptyContext())

        #expect(await approvals.entries.count == 2)
    }

    // AT-08 on the on-device path.
    @Test(.timeLimit(.minutes(1)))
    func cancelWhileAwaitingApprovalSkipsTool() async throws {
        let executions = Log<String>()
        let (dialogShown, signal) = AsyncStream.makeStream(of: Void.self)
        let tools = try ToolApprovalGate.wrap(
            [RegisteredTool(makeTool("open_line_share", executions: executions), risk: .externalSideEffect)]
        ) { _ in
            signal.yield()
            try? await Task.sleep(for: .seconds(30))
            return .approveOnce
        }
        let tool = try #require(tools.first)

        let task = Task { try await tool.execute(arguments: rawArgs, context: EmptyContext()) }
        var iterator = dialogShown.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await executions.entries.isEmpty)
    }

    @Test func forwardsToolMetadata() throws {
        let inner = try makeTool("open_line_share", executions: Log<String>())
        let tools = ToolApprovalGate.wrap(
            [RegisteredTool(inner, risk: .externalSideEffect), RegisteredTool(inner, risk: .readOnly)]
        ) { _ in .deny(reason: nil) }

        #expect(tools.map(\.name) == ["open_line_share", "open_line_share"])
        #expect(tools.allSatisfy { $0.description == inner.description })
        #expect(tools.allSatisfy { $0.parametersSchema == inner.parametersSchema })
        #expect(tools.map(\.isReadOnly) == [false, true])
    }
}
