import AgentRunKit
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

struct TextParams: Codable, SchemaProviding, Sendable {
    let text: String
}

actor Log<Entry: Sendable> {
    private(set) var entries: [Entry] = []

    func append(_ entry: Entry) {
        entries.append(entry)
    }
}

private let textArgs = #"{"text":"10分遅れます"}"#

private func makeTool(_ name: String, executions: Log<String>) throws -> any AnyTool<EmptyContext> {
    try Tool<TextParams, String, EmptyContext>(name: name, description: "test tool \(name)") { params, _ in
        await executions.append(params.text)
        return "ok"
    }
}

private func toolResult(named name: String, in messages: [ChatMessage]) -> String? {
    for case let .tool(_, toolName, content) in messages where toolName == name {
        return content
    }
    return nil
}

struct AgentRunnerTests {
    @Test func finishToolEndsRunWithContent() async throws {
        let runner = AgentRunner<EmptyContext>(client: ScriptedLLMClient([.finish("下書きです")]), tools: [])

        let outcome = try await runner.run("LINE文を作って", context: EmptyContext()) { _ in .deny(reason: nil) }

        #expect(outcome == .completed("下書きです"))
    }

    @Test func readOnlyToolRunsWithoutAskingForApproval() async throws {
        let executions = Log<String>()
        let approvals = Log<PendingApproval>()
        let client = ScriptedLLMClient([.callTool(name: "read_input", arguments: textArgs), .finish("done")])
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("read_input", executions: executions), risk: .readOnly)]
        )

        let outcome = try await runner.run("go", context: EmptyContext()) { request in
            await approvals.append(request)
            return .deny(reason: nil)
        }

        #expect(outcome == .completed("done"))
        #expect(await executions.entries == ["10分遅れます"])
        #expect(await approvals.entries.isEmpty)
    }

    // AT-05: denying a side-effect tool must not run it.
    @Test func deniedSideEffectToolIsNeverExecuted() async throws {
        let executions = Log<String>()
        let approvals = Log<PendingApproval>()
        let client = ScriptedLLMClient([.callTool(name: "open_line_share", arguments: textArgs), .finish("cancelled")])
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("open_line_share", executions: executions), risk: .externalSideEffect)]
        )

        let outcome = try await runner.run("go", context: EmptyContext()) { request in
            await approvals.append(request)
            return .deny(reason: nil)
        }

        #expect(outcome == .completed("cancelled"))
        #expect(await executions.entries.isEmpty)
        let requests = await approvals.entries
        #expect(requests.count == 1)
        #expect(requests.first?.risk == .externalSideEffect)
        #expect(requests.first?.arguments == textArgs)
        let feedback = toolResult(named: "open_line_share", in: await client.lastRequest)
        #expect(feedback?.contains("denied") == true)
    }

    @Test func approvedSideEffectToolRunsOnce() async throws {
        let executions = Log<String>()
        let client = ScriptedLLMClient([.callTool(name: "open_line_share", arguments: textArgs), .finish("opened")])
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("open_line_share", executions: executions), risk: .externalSideEffect)]
        )

        let outcome = try await runner.run("go", context: EmptyContext()) { _ in .approveOnce }

        #expect(outcome == .completed("opened"))
        #expect(await executions.entries == ["10分遅れます"])
    }

    // Duplicate-share guard: "allow for session" must not cover a second LINE share.
    @Test func sessionApprovalIsDowngradedForExternalSideEffects() async throws {
        let executions = Log<String>()
        let approvals = Log<PendingApproval>()
        let client = ScriptedLLMClient([
            .callTool(name: "open_line_share", arguments: textArgs),
            .callTool(name: "open_line_share", arguments: textArgs),
            .finish("done")
        ])
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("open_line_share", executions: executions), risk: .externalSideEffect)]
        )

        _ = try await runner.run("go", context: EmptyContext()) { request in
            await approvals.append(request)
            return .approveForSession
        }

        #expect(await approvals.entries.count == 2)
        #expect(await executions.entries.count == 2)
    }

    @Test func sessionApprovalIsHonouredForAppInternalWrites() async throws {
        let executions = Log<String>()
        let approvals = Log<PendingApproval>()
        let client = ScriptedLLMClient([
            .callTool(name: "save_note", arguments: textArgs),
            .callTool(name: "save_note", arguments: textArgs),
            .finish("done")
        ])
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("save_note", executions: executions), risk: .appInternalWrite)]
        )

        _ = try await runner.run("go", context: EmptyContext()) { request in
            await approvals.append(request)
            return .approveForSession
        }

        #expect(await approvals.entries.count == 1)
        #expect(await executions.entries.count == 2)
    }

    // AT-09: a model that never finishes is stopped at the step limit.
    @Test func runawayLoopStopsAtStepLimit() async throws {
        let executions = Log<String>()
        let client = ScriptedLLMClient([.callTool(name: "read_input", arguments: textArgs)], repeatLastStep: true)
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("read_input", executions: executions), risk: .readOnly)],
            limits: AgentLimits(maxSteps: 3)
        )

        let outcome = try await runner.run("go", context: EmptyContext()) { _ in .deny(reason: nil) }

        #expect(outcome == .stepLimitReached(limit: 3))
        #expect(await client.generateCallCount == 3)
        #expect(await executions.entries.count == 3)
    }

    // AT-08: cancelling while the approval dialog is open must not run the tool.
    @Test(.timeLimit(.minutes(1)))
    func cancelWhileAwaitingApprovalSkipsTool() async throws {
        let executions = Log<String>()
        let client = ScriptedLLMClient([.callTool(name: "open_line_share", arguments: textArgs), .finish("done")])
        let runner = try AgentRunner(
            client: client,
            tools: [RegisteredTool(makeTool("open_line_share", executions: executions), risk: .externalSideEffect)]
        )
        let (dialogShown, signal) = AsyncStream.makeStream(of: Void.self)

        let task = Task {
            try await runner.run("go", context: EmptyContext()) { _ in
                signal.yield()
                try? await Task.sleep(for: .seconds(30))
                return .approveOnce
            }
        }
        var iterator = dialogShown.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        #expect(try await task.value == .cancelled)
        #expect(await executions.entries.isEmpty)
    }

    @Test func decisionMapping() {
        #expect(AgentRunner<EmptyContext>.sdkDecision(for: .approveOnce, risk: .externalSideEffect) == .approve)
        #expect(AgentRunner<EmptyContext>.sdkDecision(for: .approveForSession, risk: .externalSideEffect) == .approve)
        #expect(AgentRunner<EmptyContext>.sdkDecision(for: .approveForSession, risk: .appInternalWrite) == .approveAlways)
        #expect(AgentRunner<EmptyContext>.sdkDecision(for: .approveForSession, risk: .appInternalDelete) == .approve)
        #expect(AgentRunner<EmptyContext>.sdkDecision(for: .deny(reason: "no"), risk: .readOnly) == .deny(reason: "no"))
    }
}
