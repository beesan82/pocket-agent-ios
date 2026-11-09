import Foundation
import PocketAgentCore

enum TranscriptionCheckAudioError: Error {
    /// The bundled asset is missing or does not decode to a WAV file.
    case unavailable
}

/// The bundled synthesized readings of the fixed check passages (ADR-044)
/// and of the frozen experiment series E (ADR-049). They ship as base64
/// text — the repository intake path cannot carry binaries — and are
/// restored to WAV files under the caches directory on first use.
/// The audio is synthesized speech of the passages only; no real voice is bundled.
enum TranscriptionCheckAudio {
    static let resourceExtension = "wav.b64"

    static func resourceName(for passage: TranscriptionCheckPassage) -> String {
        switch passage {
        case .readingAloud: return "passage-a"
        case .monologueMemo: return "passage-b"
        case .meetingTechnical: return "passage-c"
        }
    }

    static func resourceName(for passage: ExperimentPassage) -> String {
        switch passage {
        case .e1: return "passage-e1"
        case .e2: return "passage-e2"
        case .e3: return "passage-e3"
        case .e4: return "passage-e4"
        case .e5: return "passage-e5"
        }
    }

    /// The raw base64 text resource, or nil when it is not in the bundle.
    static func encodedData(for passage: TranscriptionCheckPassage, in bundle: Bundle = .main) -> Data? {
        encodedResourceData(named: resourceName(for: passage), in: bundle)
    }

    /// The raw base64 text resource, or nil when it is not in the bundle.
    static func encodedData(for passage: ExperimentPassage, in bundle: Bundle = .main) -> Data? {
        encodedResourceData(named: resourceName(for: passage), in: bundle)
    }

    private static func encodedResourceData(named name: String, in bundle: Bundle) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: resourceExtension)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The decoded WAV bytes, or nil when the asset is missing or not a RIFF/WAVE file.
    static func wavData(for passage: TranscriptionCheckPassage, in bundle: Bundle = .main) -> Data? {
        decodedWavData(from: encodedData(for: passage, in: bundle))
    }

    /// The decoded WAV bytes, or nil when the asset is missing or not a RIFF/WAVE file.
    static func wavData(for passage: ExperimentPassage, in bundle: Bundle = .main) -> Data? {
        decodedWavData(from: encodedData(for: passage, in: bundle))
    }

    private static func decodedWavData(from encoded: Data?) -> Data? {
        guard let encoded,
              let text = String(data: encoded, encoding: .utf8),
              let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]),
              data.count > 44,
              data.starts(with: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        else { return nil }
        return data
    }

    /// Where restored WAV files live (app caches; safe to delete, they are rebuilt on demand).
    static var restoreDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TranscriptionCheckAudio", isDirectory: true)
    }

    /// Restores the passage's WAV into `directory` (created as needed) and returns its URL.
    /// An existing file with the same byte count is reused.
    static func wavFileURL(
        for passage: TranscriptionCheckPassage, in bundle: Bundle = .main, directory: URL
    ) throws -> URL {
        try restoreWavFile(named: resourceName(for: passage), in: bundle, directory: directory)
    }

    /// Restores the passage's WAV into `directory` (created as needed) and returns its URL.
    /// An existing file with the same byte count is reused.
    static func wavFileURL(
        for passage: ExperimentPassage, in bundle: Bundle = .main, directory: URL
    ) throws -> URL {
        try restoreWavFile(named: resourceName(for: passage), in: bundle, directory: directory)
    }

    private static func restoreWavFile(named name: String, in bundle: Bundle, directory: URL) throws -> URL {
        guard let data = decodedWavData(from: encodedResourceData(named: name, in: bundle)) else {
            throw TranscriptionCheckAudioError.unavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".wav")
        if (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == data.count {
            return url
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
