import Foundation
import Testing
@testable import PocketAgentCore

struct JournalPoliciesTests {
    @Test func thresholdIs200Chars() {
        #expect(SummaryPolicy.autoSummarizeThreshold == 200)
        #expect(SummaryPolicy.shouldSummarize(text: String(repeating: "あ", count: 199), modelReady: true) == false)
        #expect(SummaryPolicy.shouldSummarize(text: String(repeating: "あ", count: 200), modelReady: true))
        #expect(SummaryPolicy.shouldSummarize(text: String(repeating: "あ", count: 500), modelReady: false) == false)
    }

    @Test func diskRuleBoundary() {
        #expect(DiskSpaceRule.canDownload(modelBytes: 1000, freeBytes: 1500))
        #expect(DiskSpaceRule.canDownload(modelBytes: 1000, freeBytes: 1499) == false)
        #expect(DiskSpaceRule.canDownload(modelBytes: 0, freeBytes: 0))
        #expect(DiskSpaceRule.requiredBytes(modelBytes: 1000) == 1500)
    }
}
