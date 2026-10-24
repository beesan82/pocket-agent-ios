import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgentRuntime

private let tokyo: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    calendar.firstWeekday = 2
    return calendar
}()

private func jst(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    tokyo.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

/// Monday 2026-10-19 12:00 JST.
private let fixedNow = jst(10, 19)

private func makeAssistant(_ client: ScriptedTextClient) -> JournalAssistant {
    JournalAssistant(client: client, now: { fixedNow }, calendar: tokyo)
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var chunks: [String] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

private func limits(_ maxTokens: Int) -> [String: JSONValue] {
    ["temperature": .double(0.7), "top_p": .double(0.8), "max_tokens": .int(maxTokens),
     "repetition_penalty": .double(1.1)]
}

private func userText(_ call: ScriptedTextClient.Call?) -> String {
    guard let call, case let .user(text) = call.messages.last else { return "" }
    return text
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    var attempts = 0
    while await !condition(), attempts < 500 {
        attempts += 1
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct JournalAssistantTests {
    @Test func summaryStreamsDeltas() async throws {
        let client = ScriptedTextClient(stream: [.deltas([
            .reasoning("考え中"), .content("見出し: 歯医者\n"), .finished(usage: nil), .content("歯医者に行った。"),
            .streamClosed(terminalMarkerSeen: true)
        ])])

        let chunks = try await collect(makeAssistant(client).summarize("  歯医者に行った  \n"))

        #expect(chunks == ["見出し: 歯医者\n", "歯医者に行った。"])
        #expect(client.calls.map(\.kind) == [.stream])
        #expect(client.calls.first?.messages == [
            .system(JournalPrompts.summarySystem), .user(JournalPrompts.summaryUser(text: "歯医者に行った", recordedAt: fixedNow, calendar: tokyo))
        ])
        #expect(JournalPrompts.summarySystem.contains("見出し"))
        #expect(JournalPrompts.summaryUser(text: "歯医者に行った", recordedAt: fixedNow, calendar: tokyo).contains("歯医者に行った"))
    }

    @Test func summaryErrorPropagates() async throws {
        let client = ScriptedTextClient(stream: [.deltasThenFail([.content("途中")])])
        var chunks: [String] = []

        await #expect(throws: ScriptedTextClient.FakeError.self) {
            for try await chunk in makeAssistant(client).summarize("本文") {
                chunks.append(chunk)
            }
        }
        #expect(chunks == ["途中"])
    }

    @Test func cancellationStopsStreams() async throws {
        // Summary.
        let summaryClient = ScriptedTextClient(stream: [.hang([.content("途中")])])
        let summary = makeAssistant(summaryClient).summarize("本文")
        let summaryChunks = Log<String>()
        let summaryConsumer = Task {
            for try await chunk in summary {
                await summaryChunks.append(chunk)
            }
        }
        try await waitUntil { await summaryChunks.entries.count == 1 }
        summaryConsumer.cancel()
        _ = await summaryConsumer.result
        try await waitUntil { summaryClient.terminatedStreams == 1 }
        #expect(await summaryChunks.entries == ["途中"])
        #expect(summaryClient.terminatedStreams == 1)
    }

    @Test func requestContextCarriesLimits() async throws {
        let client = ScriptedTextClient(stream: [.deltas([.content("要約")])])
        let assistant = makeAssistant(client)

        _ = try await collect(assistant.summarize("散歩した"))

        let calls = client.calls
        #expect(calls.map(\.kind) == [.stream])
        #expect(calls.map(\.extraFields) == [limits(512)])
    }

    @Test func summaryPromptCarriesRecordTimeAndWeekday() async throws {
        let now = tokyo.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 9))!
        let client = ScriptedTextClient(stream: [.deltas([.content("見出し: 夜\n要約")])])
        let assistant = JournalAssistant(client: client, now: { now }, calendar: tokyo)

        _ = try await collect(assistant.summarize("歯医者に行った"))

        let prompt = userText(client.calls.last)
        #expect(prompt.hasPrefix("記録日時: 2026-10-20 23:09（火）\n"))
        #expect(prompt.contains("歯医者に行った"))
        #expect(JournalPrompts.summarySystem.contains("午前・午後を推測で決めない"))
    }
}

struct MeetingNotesAssistantTests {
    @Test func updateMeetingNotesSendsPreviousAndNewAndContentOnly() async throws {
        let client = ScriptedTextClient(
            generate: [], stream: [.deltas([.content("## 決まったこと\n- A"), .content("\n## 宿題\n- B")])])
        let assistant = makeAssistant(client)

        let chunks = try await collect(assistant.updateMeetingNotes(previous: "## 決まったこと\n- 旧", newText: "新しい発言です"))

        #expect(chunks.joined() == "## 決まったこと\n- A\n## 宿題\n- B")
        let call = client.calls.first
        #expect(call?.kind == .stream)
        #expect(call?.messages.first == .system(JournalPrompts.meetingNotesSystem))
        #expect(userText(call).contains("- 旧"))
        #expect(userText(call).contains("新しい発言です"))
        #expect(call?.extraFields == limits(1024))
    }

    @Test func updateMeetingNotesWithEmptyPreviousSaysNone() async throws {
        let client = ScriptedTextClient(generate: [], stream: [.deltas([.content("x")])])
        let assistant = makeAssistant(client)

        _ = try await collect(assistant.updateMeetingNotes(previous: "", newText: "はじめの発言"))

        #expect(userText(client.calls.first).contains("まだありません"))
        #expect(userText(client.calls.first).contains("はじめの発言"))
    }
}
