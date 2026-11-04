import Foundation
import PocketAgentCore

enum TranscriptionCheckAudioError: Error {
    /// The bundled asset is missing or does not decode to a WAV file.
    case unavailable
}

/// The bundled synthesized readings of the fixed check passages (ADR-044).
/// They ship as base64 text — the repository intake path cannot carry binaries —
/// and are restored to WAV files under the caches directory on first use.
/// The audio is synthesized speech of the fixed passages only; no real voice is bundled.
enum TranscriptionCheckAudio {
    static let resourceExtension = "wav.b64"

    static func resourceName(for passage: TranscriptionCheckPassage) -> String {
        switch passage {
        case .readingAloud: return "passage-a"
        case .monologueMemo: return "passage-b"
        case .meetingTechnical: return "passage-c"
        }
    }

    /// The raw base64 text resource, or nil when it is not in the bundle.
    static func encodedData(for passage: TranscriptionCheckPassage, in bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: resourceName(for: passage), withExtension: resourceExtension)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The decoded WAV bytes, or nil when the asset is missing or not a RIFF/WAVE file.
    static func wavData(for passage: TranscriptionCheckPassage, in bundle: Bundle = .main) -> Data? {
        guard let encoded = encodedData(for: passage, in: bundle),
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
        guard let data = wavData(for: passage, in: bundle) else {
            throw TranscriptionCheckAudioError.unavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(resourceName(for: passage) + ".wav")
        if (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == data.count {
            return url
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
