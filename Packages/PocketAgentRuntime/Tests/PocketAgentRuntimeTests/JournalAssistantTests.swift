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

private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 0)

    func set(_ date: Date) { lock.withLock { value = date } }
    func get() -> Date { lock.withLock { value } }
}

private func makeStore(_ items: [(Date, String)]) async throws -> (InMemoryJournalStore, [JournalEntry]) {
    let clock = DateBox()
    let store = InMemoryJournalStore(now: { clock.get() })
    var added: [JournalEntry] = []
    for (date, body) in items {
        clock.set(date)
        added.append(try await store.add(NewJournalEntry(source: .text, origin: .journal, body: body)))
    }
    return (store, added)
}

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

private let answered: ScriptedTextClient.StreamStep = .deltas([.content("答え")])

struct JournalAssistantTests {
    @Test func emptyJournalNeverCallsModel() async throws {
        let client = ScriptedTextClient(generate: [.reply(#"["歯医者"]"#)], stream: [answered])
        let (store, _) = try await makeStore([])

        let result = try await makeAssistant(client).ask("歯医者はいつ？", store: store)

        #expect(result.evidence.isEmpty)
        #expect(result.usedRecentFallback == false)
        #expect(try await collect(result.answer) == ["日誌がまだありません"])
        #expect(client.calls.isEmpty)
    }

    @Test func termsFromJSONAreUsed() async throws {
        let client = ScriptedTextClient(generate: [.reply(#"["歯医者"]"#)], stream: [answered])
        let (store, added) = try await makeStore([
            (jst(10, 10), "歯医者に行った"), (jst(10, 12), "カレーを作った"), (jst(10, 15), "散歩した")
        ])
        let question = "歯医者はいつ？"

        let result = try await makeAssistant(client).ask(question, store: store)

        #expect(result.evidence.map(\.entry.id) == [added[0].id])
        #expect(result.usedRecentFallback == false)
        #expect(try await collect(result.answer) == ["答え"])
        let calls = client.calls
        #expect(calls.map(\.kind) == [.generate, .stream])
        #expect(calls.first?.messages == [.system(JournalPrompts.termsSystem), .user(JournalPrompts.termsUser(question: question))])
        #expect(calls.last?.messages == [
            .system(JournalPrompts.answerSystem),
            .user(JournalPrompts.answerUser(
                question: question, packed: result.evidence, usedRecentFallback: false, now: fixedNow, calendar: tokyo
            ))
        ])
        #expect(JournalPrompts.termsSystem.contains("JSON"))
        #expect(JournalPrompts.termsUser(question: question).contains(question))
        #expect(!userText(calls.last).contains("直近の日誌から"))
    }

    @Test func brokenJSONFallsBackToQuestionFragments() async throws {
        for step in [ScriptedTextClient.GenerateStep.reply("歯医者について調べます"), .reply("[]"), .fail] {
            let client = ScriptedTextClient(generate: [step], stream: [answered])
            let (store, added) = try await makeStore([
                (jst(10, 10), "歯医者に行った"), (jst(10, 12), "カレーを作った")
            ])

            // Fallback terms: 「歯医者」「いつ行った」.
            let result = try await makeAssistant(client).ask("歯医者 いつ行った？", store: store)

            #expect(result.evidence.map(\.entry.id) == [added[0].id])
            #expect(result.usedRecentFallback == false)
            #expect(try await collect(result.answer) == ["答え"])
            #expect(client.calls.map(\.kind) == [.generate, .stream])
        }
    }

    @Test func dateQuestionUsesRangeEvenWithoutHits() async throws {
        // 「カレー」 only hits an entry outside last week, so the whole range is used.
        for terms in [#"["旅行"]"#, #"["カレー"]"#] {
            let client = ScriptedTextClient(generate: [.reply(terms)], stream: [answered])
            let (store, added) = try await makeStore([
                (jst(10, 5), "カレーを作った"), (jst(10, 13), "仕事が忙しかった"),
                (jst(10, 14, 8), "朝に散歩した"), (jst(10, 19, 9), "今日のこと")
            ])

            let result = try await makeAssistant(client).ask("先週なにしてた？", store: store)

            #expect(result.evidence.map(\.entry.id) == [added[2].id, added[1].id])
            #expect(result.usedRecentFallback == false)
            let prompt = userText(client.calls.last)
            // 08:00 JST on the 14th is still the 13th in UTC: dates must use the calendar's zone.
            #expect(prompt.contains("--- 日誌 (2026-10-14 08:00) ---\n朝に散歩した"))
            #expect(prompt.contains("--- 日誌 (2026-10-13 12:00) ---\n仕事が忙しかった"))
            #expect(!prompt.contains("2026-10-05"))
            #expect(!prompt.contains("今日のこと"))
        }
    }

    @Test func answerPromptContainsEvidenceOnly() async throws {
        var items: [(Date, String)] = [(jst(9, 30), "秘密のメモ 料理")]
        for day in 1...25 {
            items.append((jst(10, day), "散歩\(day)日目" + String(repeating: "あ", count: 400)))
        }
        let client = ScriptedTextClient(generate: [.reply(#"["散歩"]"#)], stream: [answered])
        let (store, _) = try await makeStore(items)
        let question = "散歩の記録は？"

        let result = try await makeAssistant(client).ask(question, store: store)

        #expect((1...20).contains(result.evidence.count))
        #expect(result.evidence.allSatisfy { $0.text.count <= 300 })
        #expect(result.evidence.reduce(0) { $0 + $1.text.count } <= 3000)
        let call = try #require(client.calls.last)
        let prompt = userText(call)
        #expect(result.evidence.allSatisfy { prompt.contains($0.text) })
        #expect(prompt.components(separatedBy: "--- 日誌 (").count - 1 == result.evidence.count)
        #expect(!prompt.contains("秘密のメモ"))
        #expect(prompt.contains(question))
        for message in call.messages {
            let text: String
            switch message {
            case let .system(value), let .user(value): text = value
            default: text = ""
            }
            #expect(!text.contains("http"))
            #expect(!text.contains("sk-"))
        }
    }

    @Test func recentFallbackIsDeclared() async throws {
        let items = (1...12).map { (jst(10, $0), "日記\($0)") }
        let client = ScriptedTextClient(generate: [.reply(#"["宇宙"]"#)], stream: [answered])
        let (store, added) = try await makeStore(items)

        let result = try await makeAssistant(client).ask("宇宙の話は？", store: store)

        #expect(result.usedRecentFallback)
        #expect(result.evidence.map(\.entry.id) == added.reversed().prefix(10).map(\.id))
        let lines = userText(client.calls.last).split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("現在日時:") == true)
        #expect(lines.dropFirst().first?.contains("直近の日誌から：") == true)
        #expect(JournalPrompts.answerSystem.contains("日誌に記録がありません"))
    }

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

        // Answer.
        let askClient = ScriptedTextClient(generate: [.reply(#"["散歩"]"#)], stream: [.hang([.content("途中")])])
        let (store, _) = try await makeStore([(jst(10, 10), "散歩した")])
        let answer = try await makeAssistant(askClient).ask("散歩は？", store: store).answer
        let answerChunks = Log<String>()
        let answerConsumer = Task {
            for try await chunk in answer {
                await answerChunks.append(chunk)
            }
        }
        try await waitUntil { await answerChunks.entries.count == 1 }
        answerConsumer.cancel()
        _ = await answerConsumer.result
        try await waitUntil { askClient.terminatedStreams == 1 }
        #expect(await answerChunks.entries == ["途中"])
        #expect(askClient.terminatedStreams == 1)
    }

    @Test func requestContextCarriesLimits() async throws {
        let client = ScriptedTextClient(
            generate: [.reply(#"["散歩"]"#)], stream: [.deltas([.content("要約")]), answered]
        )
        let (store, _) = try await makeStore([(jst(10, 10), "散歩した")])
        let assistant = makeAssistant(client)

        _ = try await collect(assistant.summarize("散歩した"))
        _ = try await collect(assistant.ask("散歩は？", store: store).answer)

        let calls = client.calls
        #expect(calls.map(\.kind) == [.stream, .generate, .stream])
        #expect(calls.map(\.extraFields) == [limits(512), limits(64), limits(384)])
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

    @Test func answerPromptCarriesCurrentTimeAndEntryTimes() async throws {
        let now = tokyo.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 9))!
        let client = ScriptedTextClient(generate: [.reply(#"["散歩"]"#)], stream: [answered])
        let entryAt = tokyo.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8, minute: 5))!
        let (store, _) = try await makeStore([(entryAt, "散歩した")])
        let assistant = JournalAssistant(client: client, now: { now }, calendar: tokyo)

        _ = try await assistant.ask("散歩は？", store: store)

        let prompt = userText(client.calls.last)
        #expect(prompt.hasPrefix("現在日時: 2026-10-20 23:09（火）\n"))
        #expect(prompt.contains("--- 日誌 (2026-10-20 08:05) ---\n散歩した"))
    }
}
