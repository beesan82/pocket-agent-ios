import AVFAudio
import Foundation
import Observation
import Speech

enum SpeechCaptureError: Error {
    case unavailable
    case noAudioFormat
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
            state = .failed(Self.installFailedText)
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
        await refreshAvailability()
        guard reason == nil else { throw SpeechCaptureError.unavailable }
        state = .preparing
        volatileText = ""
        finalText = ""
        do {
            let pipeline = try await AudioPipeline.make(locale: transcriberLocale ?? Self.japanese)
            self.pipeline = pipeline
            let transcriber = pipeline.transcriber
            resultsTask = Task { [weak self] in await self?.consume(transcriber) }
            try Self.activateSession()
            try await pipeline.startAnalyzer()
            try pipeline.startEngine()
            state = .recording
        } catch {
            await cancelPipeline()
            state = .failed(Self.startFailedText)
            throw error
        }
    }

    /// Ends input, waits until every result is final, then releases the microphone.
    func stop() async {
        guard state == .recording, let pipeline else { return }
        state = .finishing
        pipeline.stopEngine()
        await pipeline.finishAnalysis()
        await resultsTask?.value
        resultsTask = nil
        self.pipeline = nil
        Self.deactivateSession()
        volatileText = ""
        if state == .finishing { state = .idle }
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
            if state == .recording || state == .finishing {
                state = .failed(Self.transcriptionFailedText)
            }
        }
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
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
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
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
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
        converter = inputFormat == analyzerFormat ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)
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
