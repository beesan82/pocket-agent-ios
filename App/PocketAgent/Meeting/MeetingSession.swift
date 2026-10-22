import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// One meeting: live segments from a `TranscriptSource`, notes rewritten on device from the
/// transcript in increments (only while the app is in front), and one journal entry at the end.
/// Owned by the app, so leaving the tab or locking the phone does not end the recording.
@MainActor
@Observable
final class MeetingSession {
    enum State: Equatable {
        case idle, preparing, recording, paused(String), finishing, saved, failed(String)
    }

    enum NotesPhase: Equatable {
        case idle, updating, failed(String)
    }

    static let startFailedText = "会議を開始できませんでした。もう一度お試しください。"
    /// Same words as `SpeechCapture.interruptedText`; the capture reports that one itself.
    static let pausedText = "録音が中断されました。再開してください。"
    static let notesFailedText = "要点を更新できませんでした（前回の要点を表示中）。"
    static let nothingRecognizedText = "音声を認識できませんでした。"
    static let saveFailedText = "保存できませんでした。もう一度お試しください。"

    private(set) var state: State = .idle
    private(set) var segments: [TranscriptSegment] = []
    private(set) var volatileText = ""
    /// The last completed notes; a running update never changes them until it completes.
    private(set) var notes = ""
    /// The running update's partial output (display only).
    private(set) var draftNotes = ""
    private(set) var notesPhase: NotesPhase = .idle
    private(set) var startedAt: Date?
    private(set) var isForeground = true

    /// Final text not yet reflected in the notes (a running update's batch excluded).
    var pendingCharacters: Int {
        segments[(updatingUpTo ?? reflectedCount)...].reduce(0) { $0 + $1.text.count }
    }

    var modelReady: Bool { assistant != nil }

    /// Set by the screen once a usable on-device client exists; a late arrival starts an update if due.
    @ObservationIgnored var assistant: (any JournalAssisting)? {
        didSet { beginAutoUpdateIfNeeded() }
    }

    @ObservationIgnored private(set) var notesTask: Task<Void, Never>?

    /// The capture (the screen reads its availability and asks for permissions / assets).
    @ObservationIgnored let source: any TranscriptSource
    @ObservationIgnored private let store: any JournalStore
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var reflectedCount = 0
    @ObservationIgnored private var updatingUpTo: Int?
    @ObservationIgnored private var lastUpdateStartedAt: Date?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private var notesGeneration = 0
    /// Segment offsets come per capture; after 「再開」 they are shifted by this capture's start.
    @ObservationIgnored private var captureOffset: TimeInterval = 0

    init(
        source: any TranscriptSource, store: any JournalStore, assistant: (any JournalAssisting)?,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.source = source
        self.store = store
        self.assistant = assistant
        self.now = now
    }

    // MARK: Recording

    func start() async {
        switch state {
        case .preparing, .recording, .paused, .finishing: return
        case .idle, .saved, .failed: break
        }
        reset()
        startedAt = now()
        state = .preparing
        await beginCapture()
    }

    /// After an interruption or a capture failure: records again, keeping every segment so far.
    func resume() async {
        guard case .paused = state else { return }
        state = .preparing
        await beginCapture()
    }

    func setForeground(_ value: Bool) {
        isForeground = value
        if value {
            beginAutoUpdateIfNeeded()
        } else {
            // On-device generation cannot run in the background; the partial output is dropped.
            stopNotesUpdate()
        }
    }

    private func beginCapture() async {
        captureGeneration += 1
        let generation = captureGeneration
        let captureStart = now()
        do {
            let events = try await source.start()
            guard generation == captureGeneration else { return }
            captureOffset = startedAt.map { captureStart.timeIntervalSince($0) } ?? 0
            state = .recording
            consumeTask = Task { [weak self] in
                for await event in events {
                    guard let self, generation == self.captureGeneration else { return }
                    self.handle(event)
                }
                guard let self, generation == self.captureGeneration else { return }
                self.captureEnded()
            }
        } catch {
            guard generation == captureGeneration else { return }
            state = segments.isEmpty ? .failed(Self.startFailedText) : .paused(Self.startFailedText)
        }
    }

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case let .volatile(text):
            volatileText = text
        case let .final(segment):
            volatileText = ""
            segments.append(TranscriptSegment(id: segment.id, offset: captureOffset + segment.offset, text: segment.text))
            beginAutoUpdateIfNeeded()
        case let .failed(text):
            volatileText = ""
            if state == .recording { state = .paused(text) }
        }
    }

    /// The source's stream ended without a failure event while we still expected input.
    private func captureEnded() {
        volatileText = ""
        if state == .recording { state = .paused(Self.pausedText) }
    }

    // MARK: Notes

    func updateNotesNow() {
        guard isMeetingOpen,
              MeetingNotesPolicy.shouldManualUpdate(
                  pendingCharacters: pendingCharacters, modelReady: modelReady, isUpdating: notesPhase == .updating)
        else { return }
        runUpdate()
    }

    /// Ends a running update; the previous notes stay and the batch goes back to pending.
    func stopNotesUpdate() {
        guard notesPhase == .updating else { return }
        notesGeneration += 1
        notesTask?.cancel()
        notesTask = nil
        updatingUpTo = nil
        draftNotes = ""
        notesPhase = .idle
    }

    private var isMeetingOpen: Bool {
        switch state {
        case .recording, .paused, .finishing: true
        case .idle, .preparing, .saved, .failed: false
        }
    }

    private func beginAutoUpdateIfNeeded() {
        guard isMeetingOpen,
              MeetingNotesPolicy.shouldAutoUpdate(
                  pendingCharacters: pendingCharacters,
                  secondsSinceLastUpdate: lastUpdateStartedAt.map { now().timeIntervalSince($0) },
                  isForeground: isForeground, modelReady: modelReady, isUpdating: notesPhase == .updating)
        else { return }
        runUpdate()
    }

    private func runUpdate() {
        guard let assistant, notesPhase != .updating else { return }
        let upTo = segments.count
        let newText = segments[reflectedCount..<upTo].map(\.text).joined(separator: "\n")
        updatingUpTo = upTo
        lastUpdateStartedAt = now()
        notesGeneration += 1
        let generation = notesGeneration
        notesPhase = .updating
        draftNotes = ""
        let stream = assistant.updateMeetingNotes(previous: notes, newText: newText)
        notesTask = Task { [weak self] in
            var raw = ""
            do {
                // Always iterated: cancelling this task ends the stream and so the model call.
                for try await chunk in stream {
                    raw += chunk
                    guard let self, generation == self.notesGeneration else { return }
                    self.draftNotes = raw
                }
                guard let self, generation == self.notesGeneration else { return }
                self.finishUpdate(raw: raw, upTo: upTo)
            } catch {
                guard let self, generation == self.notesGeneration else { return }
                self.notesTask = nil
                self.updatingUpTo = nil
                self.draftNotes = ""
                self.notesPhase = .failed(Self.notesFailedText)
            }
        }
    }

    private func finishUpdate(raw: String, upTo: Int) {
        notesTask = nil
        updatingUpTo = nil
        draftNotes = ""
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            notesPhase = .failed(Self.notesFailedText)
            return
        }
        notes = text
        reflectedCount = upTo
        notesPhase = .idle
        beginAutoUpdateIfNeeded()
    }

    // MARK: Finish and save

    /// Stops recording, brings the notes up to date once when possible, and saves one journal entry.
    func finish() async {
        switch state {
        case .preparing, .recording, .paused: break
        case .idle, .finishing, .saved, .failed: return
        }
        state = .finishing
        captureGeneration += 1  // late events of this capture are ignored
        await source.stop()
        consumeTask?.cancel()
        consumeTask = nil
        volatileText = ""
        if notesPhase != .updating, pendingCharacters > 0, modelReady, isForeground {
            runUpdate()
        }
        if let notesTask { await notesTask.value }  // 「停止」 cancels it and returns here
        await save()
    }

    func retrySave() async {
        guard state == .failed(Self.saveFailedText) else { return }
        state = .finishing
        await save()
    }

    private func save() async {
        guard !segments.isEmpty else {
            state = .failed(Self.nothingRecognizedText)
            return
        }
        let transcript = MeetingTranscriptFormatter.text(segments)
        let title = MeetingTitle.make(start: startedAt ?? now())
        let entry = notes.isEmpty
            ? NewJournalEntry(source: .voice, origin: .journal, body: transcript, title: title)
            : NewJournalEntry(source: .voice, origin: .journal, body: notes, transcript: transcript, title: title)
        do {
            _ = try await store.add(entry)
            state = .saved
        } catch {
            state = .failed(Self.saveFailedText)
        }
    }

    /// Back to the start screen (after 「保存しました」 or a failure that is not worth retrying).
    func reset() {
        switch state {
        case .idle, .saved, .failed: break
        case .preparing, .recording, .paused, .finishing: return
        }
        stopNotesUpdate()
        consumeTask?.cancel()
        consumeTask = nil
        segments = []
        volatileText = ""
        notes = ""
        draftNotes = ""
        notesPhase = .idle
        startedAt = nil
        reflectedCount = 0
        updatingUpTo = nil
        lastUpdateStartedAt = nil
        captureOffset = 0
        state = .idle
    }
}
