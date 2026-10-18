import Testing
@testable import PocketAgentCore

struct ToolPolicyTests {
    @Test func onlyReadOnlyToolsSkipApproval() {
        #expect(!ToolRisk.readOnly.requiresApproval)
        #expect(ToolRisk.appInternalWrite.requiresApproval)
        #expect(ToolRisk.externalSideEffect.requiresApproval)
    }

    @Test func externalSideEffectsNeverGetSessionWideApproval() {
        #expect(!ToolRisk.externalSideEffect.allowsSessionWideApproval)
        #expect(ToolRisk.appInternalWrite.allowsSessionWideApproval)
    }

    @Test func limitsDefaultToTenSteps() {
        #expect(AgentLimits().maxSteps == 10)
    }

    @Test func limitsClampNonPositiveValues() {
        let limits = AgentLimits(maxSteps: 0, tokenBudget: -5)
        #expect(limits.maxSteps == 1)
        #expect(limits.tokenBudget == 1)
    }
}
