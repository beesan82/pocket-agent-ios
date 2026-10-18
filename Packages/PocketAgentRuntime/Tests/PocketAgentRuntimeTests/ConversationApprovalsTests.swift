import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

private let noteArgs = #"{"text":"メモ"}"#

private func makeNoteTool(_ name: String, executions: Log<String>) throws -> any AnyTool<EmptyContext> {
    try Tool<TextParams, String, EmptyContext>(name: name, description: "test tool \(name)") { params, _ in
        await executions.append(params.text)
        return "ok"
    }
}

private func request(_ name: String, risk: ToolRisk) -> PendingApproval {
    PendingApproval(toolName: name, toolDescription: "d", arguments: noteArgs, risk: risk)
}

struct ConversationApprovalsTests {
    @Test func sessionApprovalSpansRuns() async throws {
        let executions = Log<String>(), asked = Log<PendingApproval>()
        let approvals = ConversationApprovals()
        let handler = approvals.handler { req in
            await asked.append(req)
            return .approveForSession
        }
        for _ in 0 ..< 2 {
            let client = ScriptedLLMClient([.callTool(name: "save_note", arguments: noteArgs), .finish("done")])
            let runner = try AgentRunner(
                client: client,
                tools: [RegisteredTool(makeNoteTool("save_note", executions: executions), risk: .appInternalWrite)]
            )
            let outcome = try await runner.run("go", context: EmptyContext(), approval: handler)
            #expect(outcome == .completed("done"))
        }

        #expect(await asked.entries.count == 1)
        #expect(await executions.entries.count == 2)
    }

    @Test func deleteAlwaysAsksEvenAfterSessionApproval() async throws {
        let asked = Log<PendingApproval>()
        let approvals = ConversationApprovals()
        let handler = approvals.handler { req in
            await asked.append(req)
            return .approveForSession
        }

        _ = await handler(request("delete_note", risk: .appInternalDelete))
        _ = await handler(request("delete_note", risk: .appInternalDelete))

        #expect(await asked.entries.count == 2)
    }

    @Test func sameApprovalsCoverGatePath() async throws {
        let executions = Log<String>(), asked = Log<PendingApproval>()
        let approvals = ConversationApprovals()
        let handler = approvals.handler { req in
            await asked.append(req)
            return .approveForSession
        }
        let tools = try ToolApprovalGate.wrap(
            [RegisteredTool(makeNoteTool("save_note", executions: executions), risk: .appInternalWrite)],
            approval: handler
        )
        let tool = try #require(tools.first)

        // A Claude-path run approves first; the gate (a fresh wrap) must not ask again.
        _ = await handler(request("save_note", risk: .appInternalWrite))
        _ = try await tool.execute(arguments: Data(noteArgs.utf8), context: EmptyContext())

        #expect(await asked.entries.count == 1)
        #expect(await executions.entries.count == 1)
    }

    @Test func newConversationStartsEmpty() async {
        let asked = Log<PendingApproval>()
        let first = ConversationApprovals()
        _ = await first.handler { _ in .approveForSession }(request("save_note", risk: .appInternalWrite))

        let second = ConversationApprovals()
        _ = await second.handler { req in
            await asked.append(req)
            return .approveOnce
        }(request("save_note", risk: .appInternalWrite))

        #expect(await asked.entries.count == 1)
    }

    @Test func resetClears() async {
        let asked = Log<PendingApproval>()
        let approvals = ConversationApprovals()
        let handler = approvals.handler { req in
            await asked.append(req)
            return .approveForSession
        }
        _ = await handler(request("save_note", risk: .appInternalWrite))
        _ = await handler(request("save_note", risk: .appInternalWrite))
        #expect(await asked.entries.count == 1)

        await approvals.reset()
        _ = await handler(request("save_note", risk: .appInternalWrite))

        #expect(await asked.entries.count == 2)
    }

    @Test func decisionPassesThroughUnchanged() async {
        let approvals = ConversationApprovals()
        let deny = approvals.handler { _ in .deny(reason: "no") }
        let session = approvals.handler { _ in .approveForSession }

        #expect(await deny(request("save_note", risk: .appInternalWrite)) == .deny(reason: "no"))
        #expect(await session(request("open_line_share", risk: .externalSideEffect)) == .approveForSession)
    }
}
