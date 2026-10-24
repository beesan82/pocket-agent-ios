import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// One meeting: live segments from a `TranscriptSource`, notes rewritten on device from the
/// transcript in increments (only while the app is in front), and one journal entry at the end.
/// Owned by the app, so leaving the tab or locking the phone does not end the recording.
/// Bilingual (ja/en): a two-language capture's candidates go through `LanguageArbiter`, and each
/// accepted utterance is translated on device into the other language (best effort).
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
    /// The meeting's languages (codes from `MeetingLanguage`): one, or two for a bilingual meeting.
    /// See `setLanguages`.
    private(set) var languages: [String] = ["ja"]
    var bilingual: Bool { languages.count == 2 }

    /// Final text not yet reflected in the notes (a running update's batch excluded), counted on
    /// the Japanese side (an English utterance counts by its translation once it has one).
    var pendingCharacters: Int {
        segments[(updatingUpTo ?? reflectedCount)...].reduce(0) { $0 + $1.japaneseSide.count }
    }

    var modelReady: Bool { assistant != nil }

    /// Set by the screen once a usable on-device client exists; a late arrival starts an update if due.
    @ObservationIgnored var assistant: (any JournalAssisting)? {
        didSet { beginAutoUpdateIfNeeded() }
    }
    /// Characters of previous notes + new text one update may carry (the model's context budget);
    /// a longer backlog (after a locked stretch) is worked through in several updates.
    @ObservationIgnored var batchCharacterBudget = 3000
    static let minimumBatchCharacters = 300

    @ObservationIgnored private(set) var notesTask: Task<Void, Never>?

    /// On-device translation for bilingual meetings; nil means none (pairs not installed). Set by the screen.
    @ObservationIgnored var translator: (any Translating)? {
        didSet { queueUntranslated() }
    }
    /// How long 「終了」 waits for translations still running before saving.
    @ObservationIgnored var translationWait: Duration = .seconds(10)
    static let maxTranslationAttempts = 3
    @ObservationIgnored private(set) var translationTask: Task<Void, Never>?

    /// The capture for the current languages (the screen reads its availability and asks for permissions / assets).
    private(set) var source: any TranscriptSource
    /// Makes the capture for a list of language codes; each list's capture is made once and kept.
    @ObservationIgnored private let makeSource: @MainActor ([String]) -> any TranscriptSource
    @ObservationIgnored private var sources: [String: any TranscriptSource] = [:]
    /// The running (or last) capture is a two-language one, with these languages.
    @ObservationIgnored private var captureIsBilingual = false
    @ObservationIgnored private var captureLanguages: [String] = ["ja"]
    @ObservationIgnored private var arbiter = LanguageArbiter()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var laneVolatile: [String: String] = [:]
    @ObservationIgnored private var lastLanguage: String?
    @ObservationIgnored private var translationQueue: [UUID] = []
    @ObservationIgnored private var translatingID: UUID?
    @ObservationIgnored private var translationAttempts: [UUID: Int] = [:]
    /// Set once 「終了」 has stopped waiting for translations: nothing more is translated for this meeting.
    @ObservationIgnored private var translationsClosed = false
    /// Bumped whenever the translation worker is replaced, so a cancelled one never clears the new one.
    @ObservationIgnored private var translationGeneration = 0
    @ObservationIgnored private let store: any JournalStore
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var reflectedCount = 0
    @ObservationIgnored private var updatingUpTo: Int?
    /// The running update left segments behind for the budget; continue at once when it completes.
    @ObservationIgnored private var batchTruncated = false
    @ObservationIgnored private var lastUpdateStartedAt: Date?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private var notesGeneration = 0
    /// Segment offsets come per capture; after 「再開」 they are shifted by this capture's start.
    @ObservationIgnored private var captureOffset: TimeInterval = 0

    init(
        makeSource: @escaping @MainActor ([String]) -> any TranscriptSource,
        translator: (any Translating)? = nil, store: any JournalStore, assistant: (any JournalAssisting)?,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.makeSource = makeSource
        let first = makeSource(["ja"])
        self.source = first
        self.sources = ["ja": first]
        self.translator = translator
        self.store = store
        self.assistant = assistant
        self.now = now
    }

    /// Tests: one capture for a single language, another for any pair.
    convenience init(
        source: any TranscriptSource, bilingualSource: (any TranscriptSource)? = nil,
        translator: (any Translating)? = nil, store: any JournalStore, assistant: (any JournalAssisting)?,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.init(
            makeSource: { codes in codes.count >= 2 ? (bilingualSource ?? source) : source },
            translator: translator, store: store, assistant: assistant, now: now)
    }

    /// Chooses the next meeting's languages (one, or two different ones); ignored while a meeting is open.
    func setLanguages(_ codes: [String]) {
        switch state {
        case .idle, .saved, .failed: break
        case .preparing, .recording, .paused, .finishing: return
        }
        var chosen: [String] = []
        for code in codes where !code.isEmpty && !chosen.contains(code) { chosen.append(code) }
        chosen = Array(chosen.prefix(2))
        if chosen.isEmpty { chosen = ["ja"] }
        languages = chosen
        let key = chosen.joined(separator: "+")
        if let existing = sources[key] {
            source = existing
        } else {
            let made = makeSource(chosen)
            sources[key] = made
            source = made
        }
    }

    /// Japanese alone, or Japanese and English.
    func setBilingual(_ value: Bool) {
        setLanguages(value ? ["ja", "en"] : ["ja"])
    }

    // MARK: Recording

    func start() async {
        switch state {
        case .preparing, .recording, .paused, .finishing: return
        case .idle, .saved, .failed: break
        }
        clear(keepingAssistant: true)  // the screen set the assistant for this meeting
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
            queueUntranslated()
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
        captureLanguages = languages
        captureIsBilingual = languages.count == 2
        do {
            let events = try await source.start()
            guard generation == captureGeneration else { return }
            captureOffset = startedAt.map { captureStart.timeIntervalSince($0) } ?? 0
            state = .recording
            if captureIsBilingual {
                // Each capture restarts its clock: a fresh arbiter, decided every half second.
                arbiter = LanguageArbiter(languages: captureLanguages)
                tickTask?.cancel()
                tickTask = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.tick()
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
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
            segments.append(TranscriptSegment(
                id: segment.id, offset: captureOffset + segment.offset, text: segment.text,
                language: captureLanguages.first ?? "ja"))
            beginAutoUpdateIfNeeded()
        case let .failed(text):
            drainArbiter()
            volatileText = ""
            if state == .recording { state = .paused(text) }
        case .interruptionEnded:
            if case .paused = state {
                Task { await resume() }
            }
        case let .candidate(candidate):
            guard captureIsBilingual else { return }
            accept(arbiter.submit(candidate))
        case let .laneVolatile(language, text):
            guard captureIsBilingual else { return }
            laneVolatile[language] = text
            volatileText = laneVolatile[lastLanguage ?? language] ?? text
        }
    }

    /// The source's stream ended without a failure event while we still expected input.
    private func captureEnded() {
        drainArbiter()
        volatileText = ""
        if state == .recording { state = .paused(Self.pausedText) }
    }

    // MARK: Bilingual

    /// Decides the held utterances whose wait is over (called every half second while recording).
    func tick() {
        guard captureIsBilingual else { return }
        accept(arbiter.flush(now: source.elapsed))
    }

    private func drainArbiter() {
        tickTask?.cancel()
        tickTask = nil
        guard captureIsBilingual else { return }
        accept(arbiter.drain(now: source.elapsed))
    }

    private func accept(_ decisions: [ArbiterDecision]) {
        var added = false
        for decision in decisions {
            for candidate in decision.accepted {
                let segment = TranscriptSegment(
                    offset: captureOffset + candidate.start, text: candidate.text, language: candidate.language)
                segments.append(segment)
                lastLanguage = candidate.language
                laneVolatile[candidate.language] = nil
                enqueueTranslation(segment.id)
                added = true
            }
        }
        guard added else { return }
        volatileText = lastLanguage.flatMap { laneVolatile[$0] } ?? ""
        beginAutoUpdateIfNeeded()
    }

    /// Translations run only for the open meeting, until 「終了」 stops waiting for them.
    private var translationsOpen: Bool {
        captureIsBilingual && translator != nil && !translationsClosed && isMeetingOpen
    }

    /// The utterance will still get a translation (queued, running, or retries left).
    func isAwaitingTranslation(_ segment: TranscriptSegment) -> Bool {
        translationsOpen && segment.translation == nil
            && translationAttempts[segment.id, default: 0] < Self.maxTranslationAttempts
    }

    private func enqueueTranslation(_ id: UUID) {
        guard translationsOpen, !translationQueue.contains(id), translatingID != id else { return }
        translationQueue.append(id)
        runTranslationsIfNeeded()
    }

    /// Untranslated utterances that still have attempts left (after a failure, or a translator set late).
    private func queueUntranslated() {
        guard translationsOpen else { return }
        for segment in segments where segment.translation == nil
            && translationAttempts[segment.id, default: 0] < Self.maxTranslationAttempts {
            enqueueTranslation(segment.id)
        }
    }

    private func runTranslationsIfNeeded() {
        guard translationTask == nil, let translator, !translationQueue.isEmpty else { return }
        translationGeneration += 1
        let generation = translationGeneration
        translationTask = Task { [weak self] in
            await self?.translateQueued(with: translator, generation: generation)
        }
    }

    /// One at a time, in arrival order. A failure is counted and retried later (foreground, 「更新」).
    private func translateQueued(with translator: any Translating, generation: Int) async {
        while generation == translationGeneration, !translationQueue.isEmpty {
            let id = translationQueue.removeFirst()
            guard let segment = segments.first(where: { $0.id == id }), segment.translation == nil,
                  let target = captureLanguages.first(where: { $0 != segment.language })
            else { continue }
            translatingID = id
            var translated = false
            do {
                let output = try await translator.translate(segment.text, from: segment.language, to: target)
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if generation == translationGeneration, !trimmed.isEmpty,
                   let index = segments.firstIndex(where: { $0.id == id }) {
                    segments[index] = segments[index].withTranslation(trimmed, language: target)
                    translated = true
                }
            } catch {}
            guard generation == translationGeneration else { return }  // replaced: leave the new worker alone
            translatingID = nil
            if translated {
                beginAutoUpdateIfNeeded()  // the notes waited for this translation
            } else if !Task.isCancelled {
                translationAttempts[id, default: 0] += 1
            }
            if Task.isCancelled { break }
        }
        guard generation == translationGeneration else { return }
        translationTask = nil
    }

    // MARK: Notes

    func updateNotesNow() {
        queueUntranslated()
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
        guard let assistant, notesPhase != .updating, reflectedCount < segments.count else { return }
        let upTo = batchEnd()
        guard upTo > reflectedCount else { return }  // the next utterance is still being translated
        batchTruncated = upTo < segments.count
        let newText = segments[reflectedCount..<upTo].map(\.japaneseSide).joined(separator: "\n")
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

    /// Segments after `reflectedCount` that fit the budget. Stops before an English utterance still
    /// waiting for its translation, so the notes read Japanese (it joins once translated or given up).
    private func batchEnd() -> Int {
        let budget = max(batchCharacterBudget - notes.count, Self.minimumBatchCharacters)
        var end = reflectedCount
        var used = 0
        for index in reflectedCount..<segments.count {
            // Only a translation into Japanese changes what the notes read.
            if captureLanguages.contains("ja"), segments[index].language != "ja",
               isAwaitingTranslation(segments[index]) { break }
            let length = segments[index].japaneseSide.count
            if end > reflectedCount, used + length > budget { break }
            used += length
            end = index + 1
        }
        return end
    }

    private func finishUpdate(raw: String, upTo: Int) {
        notesTask = nil
        updatingUpTo = nil
        draftNotes = ""
        let continues = batchTruncated
        batchTruncated = false
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Output cut off by the token limit would silently drop earlier items; keep the previous notes.
        guard MeetingNotesPolicy.isComplete(text) else {
            notesPhase = .failed(Self.notesFailedText)
            return
        }
        notes = text
        reflectedCount = upTo
        notesPhase = .idle
        if continues, isMeetingOpen, isForeground {
            runUpdate()  // the rest of the backlog, without waiting for the interval
        } else {
            beginAutoUpdateIfNeeded()
        }
    }

    // MARK: Finish and save

    /// Stops recording, brings the notes up to date once when possible, and saves one journal entry.
    func finish() async {
        switch state {
        case .preparing, .recording, .paused: break
        case .idle, .finishing, .saved, .failed: return
        }
        state = .finishing
        // Stopping finalizes the last results; they arrive on the events before the stream ends.
        await source.stop()
        await consumeTask?.value
        consumeTask = nil
        drainArbiter()  // utterances still held for the language decision
        captureGeneration += 1
        volatileText = ""
        // Translations first, so the last notes update reads the Japanese side of English utterances.
        await waitForTranslations()
        if notesPhase != .updating, pendingCharacters > 0, modelReady, isForeground {
            runUpdate()
        }
        if let notesTask { await notesTask.value }  // 「停止」 cancels it and returns here
        await save()
    }

    /// Up to `translationWait` for the queue to empty; what is not translated by then is saved without.
    private func waitForTranslations() async {
        let deadline = ContinuousClock.now + translationWait
        while translationTask != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        translationsClosed = true
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translatingID = nil
        translationQueue = []
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
    /// Drops the assistant too: the screen picks the current backend / client again on the next start.
    func reset() {
        clear(keepingAssistant: false)
    }

    private func clear(keepingAssistant: Bool) {
        switch state {
        case .idle, .saved, .failed: break
        case .preparing, .recording, .paused, .finishing: return
        }
        stopNotesUpdate()
        consumeTask?.cancel()
        consumeTask = nil
        tickTask?.cancel()
        tickTask = nil
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translationQueue = []
        translatingID = nil
        translationAttempts = [:]
        translationsClosed = false
        captureIsBilingual = false
        arbiter = LanguageArbiter(languages: languages)
        laneVolatile = [:]
        lastLanguage = nil
        if !keepingAssistant {
            assistant = nil
            translator = nil
        }
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
