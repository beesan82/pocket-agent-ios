import AVFAudio
import Foundation
import Observation
import Speech

enum SpeechCaptureError: Error {
    case unavailable
    case noAudioFormat
    /// The start was superseded by `stop()` or the results stream failed while preparing.
    case interrupted
}

/// On-device Japanese speech capture: microphone → SpeechAnalyzer + SpeechTranscriber.
/// Build-only in CI; recording and transcription are verified on a real iPhone.
@MainActor
@Observable
final class SpeechCapture {
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

    private static let japanese = Locale(identifier: "ja_JP")

    private(set) var state: State = .idle
    /// Latest non-final result (replaced as recognition improves).
    private(set) var volatileText = ""
    /// All final results joined without separators (Japanese needs no spaces).
    private(set) var finalText = ""
    private(set) var reason: SpeechUnavailableReason?

    @ObservationIgnored private var transcriberLocale: Locale?
    @ObservationIgnored private var pipeline: AudioPipeline?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    /// Bumped by every `start()` and by `stop()` during preparation; a running start that
    /// sees a newer value releases its own pipeline and returns.
    @ObservationIgnored private var startGeneration = 0
    @ObservationIgnored private var resultsFailedWhilePreparing = false

    func refreshAvailability() async {
        let isAvailable = SpeechTranscriber.isAvailable
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Self.japanese)
        let installed = await SpeechTranscriber.installedLocales
        transcriberLocale = supported
        reason = SpeechAvailability.reason(
            isAvailable: isAvailable,
            supportsJapanese: supported != nil,
            assetsInstalled: installed.contains(where: Self.isJapanese),
            permissionGranted: AVAudioApplication.shared.recordPermission == .granted
                && SFSpeechRecognizer.authorizationStatus() == .authorized)
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

    /// Downloads the Japanese transcription assets. Call only from a user tap.
    func installAssets() async throws {
        do {
            try await Self.downloadAssets(locale: transcriberLocale ?? Self.japanese)
        } catch {
            // Never overwrite a running capture's state.
            if state == .idle || Self.isFailed(state) { state = .failed(Self.installFailedText) }
            await refreshAvailability()
            throw error
        }
        await refreshAvailability()
    }

    func start() async throws {
        switch state {
        case .preparing, .recording, .finishing: return
        case .idle, .failed: break
        }
        // Claim the start before any await so a double tap cannot build two pipelines.
        state = .preparing
        startGeneration += 1
        let generation = startGeneration
        resultsFailedWhilePreparing = false
        volatileText = ""
        finalText = ""
        await refreshAvailability()
        guard generation == startGeneration else { return }  // stopped meanwhile
        guard reason == nil else {
            state = .idle
            throw SpeechCaptureError.unavailable
        }
        var created: AudioPipeline?
        do {
            let pipeline = try await AudioPipeline.make(locale: transcriberLocale ?? Self.japanese)
            created = pipeline
            guard generation == startGeneration else { throw SpeechCaptureError.interrupted }
            self.pipeline = pipeline
            let transcriber = pipeline.transcriber
            resultsTask = Task { [weak self] in await self?.consume(transcriber) }
            try Self.activateSession()
            try await pipeline.startAnalyzer()
            guard generation == startGeneration, !resultsFailedWhilePreparing else {
                throw SpeechCaptureError.interrupted
            }
            try pipeline.startEngine()
            state = .recording
        } catch {
            if let created { await created.cancel() }
            let current = generation == startGeneration
            if current || (created != nil && self.pipeline === created) {
                resultsTask?.cancel()
                resultsTask = nil
                pipeline = nil
            }
            // A newer start owns the session; only the current (or a stopped, idle) start releases it.
            if current || state == .idle { Self.deactivateSession() }
            guard current else { return }  // stop() during preparation is not an error
            state = .failed(Self.startFailedText)
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
            return
        case .finishing:
            return  // another stop() is finishing
        case .idle, .recording, .failed:
            break
        }
        guard let pipeline else { return }
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
        Self.deactivateSession()
        volatileText = ""
        if state == .finishing { state = graceful ? .idle : previous }
    }

    private func consume(_ transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                // Flatten here so no AttributedString reaches the UI.
                let text = String(result.text.characters)
                if result.isFinal {
                    finalText += text
                    volatileText = ""
                } else {
                    volatileText = text
                }
            }
        } catch {
            await handleResultsFailure()
        }
    }

    private func handleResultsFailure() async {
        switch state {
        case .recording:
            // Release engine, analyzer and session first so a later start() begins clean.
            await cancelPipeline()
            state = .failed(Self.transcriptionFailedText)
        case .finishing:
            state = .failed(Self.transcriptionFailedText)  // stop() releases the pipeline
        case .preparing:
            resultsFailedWhilePreparing = true  // start() aborts before starting the engine
        case .idle, .failed:
            break
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
        Self.deactivateSession()
    }

    private static func isJapanese(_ locale: Locale) -> Bool {
        let id = locale.identifier(.bcp47)
        return id == "ja" || id.hasPrefix("ja-")
    }

    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
    }

    private static func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    nonisolated private static func downloadAssets(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}

/// Engine, converter and analyzer for one recording. Not main-actor isolated: the tap block
/// runs on the audio thread. `converter` is written once before the engine starts and then
/// only used from the tap; the other members are immutable or thread-safe.
private final class AudioPipeline: @unchecked Sendable {
    let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let engine = AVAudioEngine()
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?

    private init(transcriber: SpeechTranscriber, analyzerFormat: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzerFormat = analyzerFormat
        (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    static func make(locale: Locale) async throws -> AudioPipeline {
        // Progressive preset reports volatile (tentative) results for live display.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechCaptureError.noAudioFormat
        }
        return AudioPipeline(transcriber: transcriber, analyzerFormat: format)
    }

    func startAnalyzer() async throws {
        try await analyzer.start(inputSequence: stream)
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

    /// Stops the microphone and ends the input sequence.
    func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation.finish()
    }

    /// Finalizes all results after the input ended; falls back to an immediate finish.
    func finishAnalysis() async {
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
    }

    func cancel() async {
        stopEngine()
        await analyzer.cancelAndFinishNow()
    }

    /// Audio thread.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
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
        continuation.yield(AnalyzerInput(buffer: output))
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
