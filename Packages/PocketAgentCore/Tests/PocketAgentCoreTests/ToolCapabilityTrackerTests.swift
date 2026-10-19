import Testing
@testable import PocketAgentCore

struct ToolCapabilityTrackerTests {
    @Test func twoRescuesLimit() {
        var tracker = ToolCapabilityTracker()
        tracker.recordRescue()
        #expect(!tracker.isLimited)
        tracker.recordRescue()
        #expect(tracker.isLimited)
    }

    @Test func twoMissedIntentsLimit() {
        var tracker = ToolCapabilityTracker()
        tracker.recordNoToolCall(userMessage: "こんにちは")
        tracker.recordNoToolCall(userMessage: "こんにちは")
        #expect(!tracker.isLimited)
        tracker.recordNoToolCall(userMessage: "牛乳を覚えて")
        #expect(!tracker.isLimited)
        tracker.recordNoToolCall(userMessage: "牛乳を覚えて")
        #expect(tracker.isLimited)
    }

    @Test func nativeCallsDoNotChangeState() {
        var tracker = ToolCapabilityTracker()
        tracker.recordRescue()
        tracker.recordNativeToolCall()
        tracker.recordNativeToolCall()
        #expect(!tracker.isLimited)
        tracker.recordRescue()
        #expect(tracker.isLimited)
    }

    @Test func resetClearsEverything() {
        var tracker = ToolCapabilityTracker()
        tracker.recordRescue()
        tracker.recordRescue()
        tracker.reset()
        #expect(!tracker.isLimited)
        #expect(tracker == ToolCapabilityTracker())
    }

    @Test func intentKeywords() {
        for word in ["覚えて", "保存", "メモ", "消して", "直して"] {
            #expect(ToolCapabilityTracker.hasMemoryIntent("これを\(word)ください"), Comment(rawValue: word))
        }
        #expect(!ToolCapabilityTracker.hasMemoryIntent("おはよう"))
    }
}
