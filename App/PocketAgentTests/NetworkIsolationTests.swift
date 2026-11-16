import AgentRunKit
import Foundation
import PocketAgentCore
import PocketAgentRuntime
import SwiftData
import Testing
@testable import PocketAgent

/// Records every request that reaches the URL loading system through `URLSession.shared` while it
/// is installed, and answers HTTP 401 at once, so nothing ever leaves the test process.
///
/// Reach (ADR-053): `URLProtocol.registerClass` covers `URLSession.shared` — the session the app's
/// own code uses (`ClaudeAdapter`, `MeasurementUploader`). It does NOT see sessions built with their
/// own configuration (e.g. inside swift-huggingface's `HubClient`), sockets opened below
/// URLSession (llama.cpp, MLX), or anything Apple's frameworks do in other processes
/// (SpeechAnalyzer, Foundation Models, Translation).
final class NetworkProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URL?] = []

    static func install() {
        lock.withLock { captured = [] }
        URLProtocol.registerClass(NetworkProbeURLProtocol.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(NetworkProbeURLProtocol.self)
    }

    /// The hosts of every captured request, in order ("-" when a request had no host).
    static var requestedHosts: [String] {
        lock.withLock { captured.map { $0?.host() ?? "-" } }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.captured.append(request.url) }
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(
            #"{"type":"error","error":{"type":"authentication_error","message":"network probe"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// App-wide invariant (requirements 6.3, AT-14, ADR-053): with an on-device model selected, using
/// chat, the record (journal) and a meeting makes no network request at all.
///
/// What this suite can and cannot show:
/// - Shown: the app's own orchestration code (ChatSession, JournalCaptureSession, MeetingSession,
///   the SwiftData stores, the live Claude resolver wired in but unused) sends nothing through
///   `URLSession.shared`, even when a Claude API key is saved. The two control tests prove the probe
///   really sees such traffic, including the app's real Claude route.
/// - NOT shown (未確認の範囲): the model, speech and translation engines are replaced by fakes here,
///   so traffic inside FoundationModels, SpeechAnalyzer, Translation, mlx-swift-lm, llama.cpp or
///   swift-huggingface is outside this test. Sessions with their own configuration and raw sockets
///   are not captured either. Only a real-device run in airplane mode covers those.
///
/// Serialized: the probe is registered process-wide.
@Suite(.serialized)
@MainActor
struct NetworkIsolationTests {
    // Kept as a property: a ModelContext crashes if its container is released.
    private let container: ModelContainer
    private let repository: ConversationRepository
    private let settings: ModelSettings
    private let credentials = SpyCredentialStore(key: "test-key")

    init() throws {
        container = try AppModelContainer.make(inMemory: true)
        repository = ConversationRepository(context: container.mainContext)
        let name = "NetworkIsolationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        settings = ModelSettings(defaults: defaults)
    }

    /// Polls on the main actor; returns false on timeout instead of hanging the suite.
    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The production resolver: it would build a real `AnthropicClient` on `URLSession.shared`.
    private func makeChat(
        choice: ModelChoice, journal: any JournalStore, onDevice: any OnDeviceModelAccess
    ) throws -> ChatSession {
        ChatSession(
            conversation: try repository.create(choice: choice), repository: repository,
            notes: InMemoryNoteStore(), journal: journal, settings: settings, broker: ApprovalBroker(),
            resolve: ChatSession.liveResolver(
                credentials: credentials, availability: FixedAvailability(reason: nil), settings: settings),
            onDevice: onDevice)
    }

    // MARK: - Controls: the probe sees URLSession.shared traffic

    @Test func probeCapturesSharedSessionRequests() async throws {
        NetworkProbeURLProtocol.install()
        defer { NetworkProbeURLProtocol.uninstall() }
        let url = try #require(URL(string: "https://probe.invalid/ping"))

        let (_, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect(NetworkProbeURLProtocol.requestedHosts == ["probe.invalid"])
    }

    /// The same chat flow with Claude selected does reach the probe: so an empty capture in the
    /// on-device tests below means "nothing was sent", not "the probe was blind".
    @Test func claudeChatIsSeenByTheProbe() async throws {
        NetworkProbeURLProtocol.install()
        defer { NetworkProbeURLProtocol.uninstall() }
        settings.choice = .claude
        let session = try makeChat(
            choice: .claude, journal: InMemoryJournalStore(),
            onDevice: FakeOnDeviceModel(runner: ScriptedTurnRunner([])))

        session.send("やあ")
        #expect(try await waitUntil { !session.isBusy })

        let hosts = NetworkProbeURLProtocol.requestedHosts
        #expect(!hosts.isEmpty)
        #expect(hosts.allSatisfy { $0 == AnthropicClient.anthropicBaseURL.host() })
        // The probe's 401 is reported as a failure; nothing was answered.
        #expect(session.turns == [ChatTurn(role: .user, text: "やあ")])
    }

    // MARK: - Invariant: on-device selection sends nothing

    @Test(arguments: [ModelChoice.appleLocal, .mlxLocal])
    func onDeviceChatJournalAndMeetingMakeNoNetworkRequests(_ choice: ModelChoice) async throws {
        NetworkProbeURLProtocol.install()
        defer { NetworkProbeURLProtocol.uninstall() }
        settings.choice = choice
        // The real persistence layer, shared by the three routes like in the app.
        let journal = SwiftDataJournalStore(modelContainer: container)

        // 記録（日誌）: the backend rule never picks Claude; summarize on device, then save.
        let backend = JournalModelAccess.backend(settings: settings, availability: FixedAvailability(reason: nil))
        #expect(backend == (choice == .appleLocal ? .appleLocal : .mlxLocal))
        let capture = JournalCaptureSession(
            source: .voice, store: journal,
            assistant: FakeJournalAssistant(summaryChunks: ["見出し: 来月の計画\n会議で来月の計画を話した。"]),
            modelReady: true)
        capture.transcript = String(repeating: "今日は会議で来月の計画を話した。", count: 20)
        capture.beginIfNeeded(isForeground: true)
        await capture.summaryTask?.value
        #expect(capture.phase == .summarized)
        await capture.save(useTranscriptOnly: false)
        #expect(capture.phase == .saved)

        // 会議: transcribe, update the notes on device, translate on device, title and save.
        let source = FakeTranscriptSource()
        let assistant = FakeJournalAssistant(
            summaryChunks: ["見出し: 定例会議\n要点"],
            notesChunks: ["## 決まったこと\n- A\n## 宿題\n- （なし）\n## 論点・未決\n- （なし）"])
        let meeting = MeetingSession(
            source: source, translator: FakeTranslator(), store: journal, assistant: assistant)
        await meeting.start()
        #expect(meeting.state == .recording)
        source.yield(.final(TranscriptSegment(offset: 1, text: String(repeating: "あ", count: 300))))
        #expect(try await waitUntil { assistant.notesCalls.calls.count == 1 })
        await meeting.notesTask?.value
        await meeting.finish()
        #expect(meeting.state == .saved)

        // チャット: a turn that looks the journal up (the entries saved above) and answers on device.
        let runner = ScriptedTurnRunner([[.text("来月の計画を話しました")]])
        let chat = try makeChat(choice: choice, journal: journal, onDevice: FakeOnDeviceModel(runner: runner))
        chat.send("今日の会議で何を話した？")
        #expect(try await waitUntil { chat.status == .idle && chat.turns.count == 2 })
        #expect(runner.calls.count == 1)

        // All three routes ran, and the journal holds what they saved.
        #expect(try await journal.all().count == 2)
        // The invariant: not one request, and the Claude key was never even read.
        #expect(NetworkProbeURLProtocol.requestedHosts == [])
        #expect(credentials.reads == 0)
    }
}
