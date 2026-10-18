import Foundation
import Testing
@testable import PocketAgentCore

struct ShareFlowTests {
    @Test func confirmOnlyWhileConfirming() {
        var flow = ShareFlow()
        #expect(flow.confirm() == nil)
        flow.request("こんにちは")
        #expect(flow.state == .confirming(text: "こんにちは"))
        #expect(flow.confirm() != nil)
        #expect(flow.state == .confirming(text: "こんにちは"))
        flow.didOpen(true)
        #expect(flow.confirm() == nil)
    }

    @Test func blankTextFails() {
        var flow = ShareFlow()
        flow.request("  \n ")
        #expect(flow.state == .failed("共有する文面がありません"))
        #expect(flow.confirm() == nil)
    }

    @Test func openedMessageNeverClaimsSent() {
        let message = ShareFlow.statusMessage(for: .opened)
        #expect(message != nil)
        #expect(message?.contains("送信しました") == false)
        #expect(message?.contains("送信済み") == false)
        #expect(message?.contains("未確認") == true)
    }

    @Test func failedOpenIsReported() {
        var flow = ShareFlow()
        flow.request("hello")
        flow.didOpen(false)
        #expect(flow.state == .failed("LINEを開けませんでした"))
        #expect(ShareFlow.statusMessage(for: flow.state) == "LINEを開けませんでした")
    }

    @Test func cancelReturnsToCancelled() {
        var flow = ShareFlow()
        flow.request("hello")
        flow.cancel()
        #expect(flow.state == .cancelled)
        #expect(flow.confirm() == nil)
        #expect(ShareFlow.statusMessage(for: .cancelled) == nil)
    }

    @Test func urlEncodesText() throws {
        var flow = ShareFlow()
        let text = "a b&c=日本語+"
        flow.request(text)
        #expect(flow.confirm() == (try LineShareURLBuilder.url(for: text)))
    }
}
