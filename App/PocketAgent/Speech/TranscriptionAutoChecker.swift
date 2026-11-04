import AVFAudio
import Foundation
import PocketAgentCore
import Speech

enum TranscriptionAutoCheckError: Error {
    /// The bundled synthesized audio is missing or cannot be restored.
    case audioUnavailable
    /// The SpeechTranscriber language assets could not be downloaded.
    case assetsInstallFailed
    /// No audio format is available for the transcriber.
    case noAudioFormat
    /// The restored WAV cannot be read as audio.
    case unreadableAudio
    /// The analyzer or its results stream failed.
    case recognitionFailed

    var userMessage: String {
        switch self {
        case .audioUnavailable:
            return "チェック用音声が見つかりませんでした。"
        case .assetsInstallFailed:
            return "音声認識データを入手できませんでした。通信環境を確認して再試行してください。"
        case .noAudioFormat, .unreadableAudio, .recognitionFailed:
            return "自動チェックの認識に失敗しました。もう一度お試しください。"
        }
    }
}

/// Feeds one bundled synthesized passage to a SpeechAnalyzer configured exactly like the
/// journal live path and returns the recognized text (final results joined, as the live
/// capture joins them). Recognition is verified on a real device only; CI covers the
/// asset handling and the scoring (ADR-044).
struct TranscriptionAutoChecker {
    func transcribe(passage: TranscriptionCheckPassage) async throws -> String {
        try await transcribeSegments(passage: passage, alternatives: false)
            .map(\.text)
            .joined()
    }

    /// Recognizes one passage and returns every final result with the engine's
    /// alternative readings of it. With `alternatives` off, the transcriber is
    /// the standard configuration (the live path's preset, ADR-044) and the
    /// candidate lists come back empty. With it on, the transcriber is built
    /// from the composed options (`ProgressiveTranscriber`) so final results
    /// carry alternatives — the input to Experiment 1's ON/OFF comparison.
    /// Recognition settings are otherwise identical either way.
    func transcribeSegments(
        passage: TranscriptionCheckPassage, alternatives: Bool
    ) async throws -> [TranscriptionSegmentCandidates] {
        let fileURL: URL
        do {
            fileURL = try TranscriptionCheckAudio.wavFileURL(
                for: passage, directory: TranscriptionCheckAudio.restoreDirectory)
        } catch {
            throw TranscriptionAutoCheckError.audioUnavailable
        }
        // Same locale resolution as the live path (SpeechCapture); the
        // configuration is the preset, or the composed options for the
        // alternatives experiment.
        let requested = Locale(identifier: "ja_JP")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested
        let transcriber = alternatives
            ? ProgressiveTranscriber.make(locale: locale)
            : ProgressiveTranscriber.makeStandard(locale: locale)
        try await ensureAssets(for: transcriber, locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionAutoCheckError.noAudioFormat
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionAutoCheckError.unreadableAudio
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultsTask = Task {
            var segments: [TranscriptionSegmentCandidates] = []
            for try await result in transcriber.results {
                if result.isFinal {
                    segments.append(TranscriptionSegmentCandidates(
                        text: String(result.text.characters),
                        alternatives: result.alternatives.map { String($0.characters) }))
                }
            }
            return segments
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
            try await analyzer.start(inputSequence: stream)
            try Self.feed(file: file, format: analyzerFormat, continuation: continuation)
            continuation.finish()
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
            return try await resultsTask.value
        } catch let error as TranscriptionAutoCheckError {
            resultsTask.cancel()
            throw error
        } catch {
            resultsTask.cancel()
            throw TranscriptionAutoCheckError.recognitionFailed
        }
    }

    /// Downloads the transcriber's language assets when they are not installed yet,
    /// through the same AssetInventory path as the live capture's install flow.
    private func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.language.languageCode == locale.language.languageCode }) {
            return
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionAutoCheckError.assetsInstallFailed
        }
    }

    /// Reads the whole file and yields it in chunks, converted to the analyzer format.
    private static func feed(
        file: AVAudioFile, format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let fileFormat = file.processingFormat
        let converter = fileFormat == format ? nil : AVAudioConverter(from: fileFormat, to: format)
        if fileFormat != format, converter == nil {
            throw TranscriptionAutoCheckError.noAudioFormat
        }
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frames = AVAudioFrameCount(min(remaining, 8192))
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frames)
            else { break }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                continue
            }
            let ratio = format.sampleRate / fileFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
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
            if status != .error, output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
            }
        }
    }
}

/// Hands one buffer to AVAudioConverter's input block, then reports "no data now"
/// (same pattern as the live capture's audio pipeline).
private final class OneShotBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
