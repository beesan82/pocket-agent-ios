import AVFAudio
import CoreMedia
import Foundation
import Observation
import PocketAgentCore
import Speech

enum SpeechCaptureError: Error {
    case unavailable
    case noAudioFormat
    /// The start was superseded by `stop()` or the results stream failed while preparing.
    case interrupted
}

/// On-device speech capture: microphone → SpeechAnalyzer + SpeechTranscriber, Japanese by default.
/// With two locales (ja + en) the same microphone audio feeds one analyzer per language and each
/// final result is reported as a `.candidate` with its confidence; the consumer picks the language.
/// Build-only in CI; recording and transcription are verified on a real iPhone.
@MainActor
@Observable
final class SpeechCapture: TranscriptSource {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finishing
        case failed(String)
    }

    static let startFailedText = "音声入力を開始できませんでした。もう一度お試しください。"
    static let installFailedText = "音声認識データを入手できませんでした。通信環境を確認して再試行してください。"
    static let transcriptionFailedText = "文字起こし中に問題が発生しました。もう一度お試しください。"
    /// A phone call or another app took the audio session (meeting mode offers 「再開」).
    static let interruptedText = "録音が中断されました。再開してください。"

    private static let japanese = Locale(identifier: "ja_JP")
    static let english = Locale(identifier: "en_US")

    private(set) var state: State = .idle
    /// Latest non-final result (replaced as recognition improves).
    private(set) var volatileText = ""
    /// All final results joined without separators (Japanese needs no spaces).
    private(set) var finalText = ""
    private(set) var reason: SpeechUnavailableReason?
    /// Bilingual capture: the latest tentative text per language ("ja" / "en").
    private(set) var laneVolatile: [String: String] = [:]

    /// The requested locales: Japanese first, then (bilingual) English.
    @ObservationIgnored let locales: [Locale]
    var isBilingual: Bool { locales.count > 1 }
    @ObservationIgnored private var transcriberLocales: [Locale] = []
    @ObservationIgnored private var pipeline: AudioPipeline?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    /// Bumped by every `start()` and by `stop()` during preparation; a running start that
    /// sees a newer value releases its own pipeline and returns.
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var resultsFailedWhilePreparing = false
    /// Events of the current capture (`start()` makes a new stream; it ends with the capture).
    @ObservationIgnored private var events: AsyncStream<TranscriptEvent>.Continuation?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var interruptionObserver: (any NSObjectProtocol)?
    /// True between this capture's session activation and its deactivation (the session is shared).
    @ObservationIgnored private var holdsSession = false
    /// Captures holding the shared `AVAudioSession`; it is deactivated when the last one lets go.
    private static var sessionHolders = 0

    init(locales: [Locale] = [Locale(identifier: "ja_JP")]) {
        self.locales = locales.isEmpty ? [Self.japanese] : locales
    }

    func refreshAvailability() async {
        let isAvailable = SpeechTranscriber.isAvailable
        let installed = await SpeechTranscriber.installedLocales
        var supported: [Locale?] = []
        for locale in locales {
            supported.append(await SpeechTranscriber.supportedLocale(equivalentTo: locale))
        }
        transcriberLocales = zip(locales, supported).map { $1 ?? $0 }
        let assets = locales.map { locale in installed.contains { Self.sameLanguage($0, locale) } }
        reason = SpeechAvailability.reason(
            isAvailable: isAvailable,
            supportsJapanese: supported.first.flatMap { $0 } != nil,
            assetsInstalled: assets.first ?? false,
            permissionGranted: AVAudioApplication.shared.recordPermission == .granted
                && SFSpeechRecognizer.authorizationStatus() == .authorized,
            supportsEnglish: supported.count < 2 || supported[1] != nil,
            englishAssetsInstalled: assets.count < 2 || assets[1])
    }

    /// Asks for microphone and speech recognition permission (only those not yet decided).
    func requestPermissions() async {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await Self.requestMicrophone()
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await Self.requestSpeechRecognition()
        }
        await refreshAvailability()
    }

    /// Downloads the transcription assets of every locale. Call only from a user tap.
    func installAssets() async throws {
        do {
            try await Self.downloadAssets(locales: transcriberLocales.isEmpty ? locales : transcriberLocales)
        } catch {
            // Never overwrite a running capture's state.
            if state == .idle || Self.isFailed(state) { state = .failed(Self.installFailedText) }
            await refreshAvailability()
            throw error
        }
        await refreshAvailability()
    }

    /// Starts recording and returns this capture's events. A call while a capture is running or
    /// stopping returns an already-finished stream (the running capture keeps its own).
    @discardableResult
    func start() async throws -> AsyncStream<TranscriptEvent> {
        switch state {
        case .preparing, .recording, .finishing: return AsyncStream { $0.finish() }
        case .idle, .failed: break
        }
        // Claim the start before any await so a double tap cannot build two pipelines.
        state = .preparing
        startGeneration += 1
        let generation = startGeneration
        resultsFailedWhilePreparing = false
        volatileText = ""
        finalText = ""
        laneVolatile = [:]
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        events?.finish()
        events = continuation
        startedAt = Date()
        await refreshAvailability()
        guard generation == startGeneration else { return stream }  // stopped meanwhile
        guard reason == nil else {
            state = .idle
            finishEvents()
            throw SpeechCaptureError.unavailable
        }
        var created: AudioPipeline?
        do {
            let pipeline = try await AudioPipeline.make(
                locales: transcriberLocales.isEmpty ? locales : transcriberLocales, bilingual: isBilingual)
            created = pipeline
            guard generation == startGeneration else { throw SpeechCaptureError.interrupted }
            self.pipeline = pipeline
            let lanes = pipeline.lanes
            let bilingual = isBilingual
            // One main-actor task per language; `resultsTask` ends when all of them have ended and
            // cancelling it cancels them.
            let laneTasks = lanes.map { lane in
                let transcriber = lane.transcriber
                let language = bilingual ? lane.language : nil
                return Task { [weak self] in await self?.consume(transcriber, language: language) }
            }
            resultsTask = Task {
                await withTaskCancellationHandler {
                    for task in laneTasks { await task.value }
                } onCancel: {
                    laneTasks.forEach { $0.cancel() }
                }
            }
            try activateSession()
            try await pipeline.startAnalyzer()
            guard generation == startGeneration, !resultsFailedWhilePreparing else {
                throw SpeechCaptureError.interrupted
            }
            try pipeline.startEngine()
            startedAt = Date()  // audio time 0 of the analyzers
            observeInterruptions()
            state = .recording
            return stream
        } catch {
            if let created { await created.cancel() }
            let current = generation == startGeneration
            if current || (created != nil && self.pipeline === created) {
                resultsTask?.cancel()
                resultsTask = nil
                pipeline = nil
            }
            // A newer start owns the session; only the current (or a stopped, idle) start releases it.
            if current || state == .idle { deactivateSession() }
            guard current else { return stream }  // stop() during preparation is not an error
            state = .failed(Self.startFailedText)
            finishEvents()
            throw error
        }
    }

    /// Ends input, waits until every result is final, then releases the microphone.
    /// Releases a leftover pipeline in any state; during preparation it cancels the start.
    func stop() async {
        switch state {
        case .preparing:
            startGeneration += 1  // the running start() releases its own pipeline
            state = .idle
            finishEvents()
            return
        case .finishing:
            return  // another stop() is finishing
        case .idle, .recording, .failed:
            break
        }
        guard let pipeline else {
            // Nothing to release (e.g. after an interruption); the events may still be waiting for `.ended`.
            stopObservingInterruptions()
            finishEvents()
            return
        }
        let previous = state
        let graceful = previous == .recording
        state = .finishing
        if graceful {
            pipeline.stopEngine()
            await pipeline.finishAnalysis()
            await resultsTask?.value
        } else {
            await pipeline.cancel()
            resultsTask?.cancel()
        }
        resultsTask = nil
        if self.pipeline === pipeline { self.pipeline = nil }
        stopObservingInterruptions()
        deactivateSession()
        volatileText = ""
        laneVolatile = [:]
        if state == .finishing { state = graceful ? .idle : previous }
        finishEvents()
    }

    private func finishEvents() {
        events?.finish()
        events = nil
    }

    /// Seconds from the start of this capture for a result; the audio time when the analyzer gives one.
    private func offset(for range: CMTimeRange) -> TimeInterval {
        let seconds = range.start.seconds
        if seconds.isFinite, seconds >= 0 { return seconds }
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Seconds since this capture started (the clock of bilingual candidates).
    var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// `language` is nil for a single-language capture (`.final` / `.volatile` events as before).
    private func consume(_ transcriber: SpeechTranscriber, language: String?) async {
        do {
            for try await result in transcriber.results {
                // Flatten here so no AttributedString reaches the UI.
                let text = String(result.text.characters)
                if let language {
                    report(result, text: text, language: language)
                    continue
                }
                if result.isFinal {
                    finalText += text
                    volatileText = ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        events?.yield(.final(TranscriptSegment(offset: offset(for: result.range), text: trimmed)))
                    }
                } else {
                    volatileText = text
                    events?.yield(.volatile(text))
                }
            }
        } catch {
            await handleResultsFailure()
        }
    }

    private func report(_ result: SpeechTranscriber.Result, text: String, language: String) {
        guard result.isFinal else {
            laneVolatile[language] = text
            return
        }
        laneVolatile[language] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var runs: [(characters: Int, confidence: Double?)] = []
        for run in result.text.runs {
            let characters = result.text[run.range].characters.count
            runs.append((characters, run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self].map { Double($0) }))
        }
        let arrived = elapsed
        let start = result.range.start.seconds
        let end = result.range.end.seconds
        let valid = start.isFinite && end.isFinite && start >= 0 && end >= start
        events?.yield(.candidate(LaneCandidate(
            language: language, text: trimmed, confidence: ConfidenceMath.weightedAverage(runs),
            start: valid ? start : arrived, end: valid ? end : arrived, arrivedAt: arrived)))
    }

    private func handleResultsFailure() async {
        switch state {
        case .recording:
            // Release engine, analyzer and session first so a later start() begins clean.
            await cancelPipeline()
            state = .failed(Self.transcriptionFailedText)
            events?.yield(.failed(Self.transcriptionFailedText))
            finishEvents()
        case .finishing:
            state = .failed(Self.transcriptionFailedText)  // stop() releases the pipeline
            events?.yield(.failed(Self.transcriptionFailedText))
        case .preparing:
            resultsFailedWhilePreparing = true  // start() aborts before starting the engine
        case .idle, .failed:
            break
        }
    }

    /// A call or another app's audio ends this capture (the system stops the engine anyway).
    /// The events stay open until the interruption ends: `.interruptionEnded` when the system
    /// allows recording again (meeting mode restarts), otherwise the stream just ends.
    private func observeInterruptions() {
        stopObservingInterruptions()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.handleInterruption()
                case .ended: self?.handleInterruptionEnded(shouldResume: shouldResume)
                @unknown default: break
                }
            }
        }
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        guard state == .failed(Self.interruptedText) else { return }
        stopObservingInterruptions()
        if shouldResume { events?.yield(.interruptionEnded) }
        finishEvents()
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private func handleInterruption() {
        guard state == .recording else { return }
        Task { [weak self] in
            guard let self, state == .recording else { return }
            await cancelPipeline()
            state = .failed(Self.interruptedText)
            events?.yield(.failed(Self.interruptedText))
            observeInterruptions()  // kept for `.ended`; a new start() or stop() replaces or removes it
        }
    }

    private static func isFailed(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func cancelPipeline() async {
        if let pipeline { await pipeline.cancel() }
        resultsTask?.cancel()
        resultsTask = nil
        pipeline = nil
        stopObservingInterruptions()
        deactivateSession()
    }

    private static func sameLanguage(_ lhs: Locale, _ rhs: Locale) -> Bool {
        lhs.language.languageCode == rhs.language.languageCode
    }

    /// The session is shared by every `SpeechCapture` (journal dictation, meeting): activation is
    /// idempotent, deactivation happens only when the last holder lets go, so a short dictation
    /// cannot cut off a running meeting.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        if !holdsSession {
            holdsSession = true
            Self.sessionHolders += 1
        }
    }

    private func deactivateSession() {
        guard holdsSession else { return }
        holdsSession = false
        Self.sessionHolders = max(0, Self.sessionHolders - 1)
        if Self.sessionHolders == 0 {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // Callbacks below arrive on arbitrary queues; nonisolated + @Sendable keeps them off the main actor.

    nonisolated private static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { @Sendable granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func requestSpeechRecognition() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    nonisolated private static func downloadAssets(locales: [Locale]) async throws {
        let transcribers = locales.map { SpeechTranscriber(locale: $0, preset: .progressiveTranscription) }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: transcribers) {
            try await request.downloadAndInstall()
        }
    }
}

/// Engine, converter and one analyzer per language for one recording. Not main-actor isolated:
/// the tap block runs on the audio thread. `converter` is written once before the engine starts and
/// then only used from the tap; the other members are immutable or thread-safe.
private final class AudioPipeline: @unchecked Sendable {
    struct Lane: Sendable {
        let language: String
        let transcriber: SpeechTranscriber
    }

    let lanes: [Lane]
    private let analyzers: [SpeechAnalyzer]
    private let analyzerFormat: AVAudioFormat
    private let engine = AVAudioEngine()
    private let streams: [AsyncStream<AnalyzerInput>]
    private let continuations: [AsyncStream<AnalyzerInput>.Continuation]
    private var converter: AVAudioConverter?

    private init(lanes: [Lane], analyzerFormat: AVAudioFormat) {
        self.lanes = lanes
        self.analyzers = lanes.map { SpeechAnalyzer(modules: [$0.transcriber]) }
        self.analyzerFormat = analyzerFormat
        let made = lanes.map { _ in AsyncStream.makeStream(of: AnalyzerInput.self) }
        streams = made.map { $0.stream }
        continuations = made.map { $0.continuation }
    }

    static func make(locales: [Locale], bilingual: Bool) async throws -> AudioPipeline {
        let lanes = locales.map { locale in
            // Progressive (volatile + fast results) for live display; bilingual adds the time range
            // and per-word confidence the language decision needs.
            let transcriber = bilingual
                ? SpeechTranscriber(
                    locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.audioTimeRange, .transcriptionConfidence])
                : SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            return Lane(language: locale.language.languageCode?.identifier ?? "ja", transcriber: transcriber)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: lanes.map { $0.transcriber }) else {
            throw SpeechCaptureError.noAudioFormat
        }
        return AudioPipeline(lanes: lanes, analyzerFormat: format)
    }

    func startAnalyzer() async throws {
        for (analyzer, stream) in zip(analyzers, streams) {
            try await analyzer.start(inputSequence: stream)
        }
    }

    func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        if inputFormat == analyzerFormat {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                throw SpeechCaptureError.noAudioFormat
            }
            converter = made
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [self] buffer, _ in
            feed(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the microphone and ends the input sequences.
    func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuations.forEach { $0.finish() }
    }

    /// Finalizes all results after the input ended; falls back to an immediate finish.
    func finishAnalysis() async {
        for analyzer in analyzers {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    func cancel() async {
        stopEngine()
        for analyzer in analyzers {
            await analyzer.cancelAndFinishNow()
        }
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        for continuation in continuations {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Audio thread.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            yield(buffer)
            return
        }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        let source = OneShotBuffer(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let next = source.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        guard status != .error, output.frameLength > 0 else { return }
        yield(output)
    }
}

/// Hands one buffer to AVAudioConverter's input block, then reports "no data now".
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
