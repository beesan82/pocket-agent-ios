import AVFoundation
import Foundation
import Testing
@testable import PocketAgent
import PocketAgentCore

struct TranscriptionAutoCheckTests {
    @Test func resourceNamesMatchThePassages() {
        #expect(TranscriptionCheckAudio.resourceName(for: .readingAloud) == "passage-a")
        #expect(TranscriptionCheckAudio.resourceName(for: .monologueMemo) == "passage-b")
        #expect(TranscriptionCheckAudio.resourceName(for: .meetingTechnical) == "passage-c")
        #expect(TranscriptionCheckAudio.resourceExtension == "wav.b64")
    }

    @Test func everyPassageHasBundledAudio() {
        for passage in TranscriptionCheckPassage.allCases {
            #expect(TranscriptionCheckAudio.encodedData(for: passage) != nil,
                    "missing bundled audio for \(passage.label)")
        }
    }

    @Test func restoredAudioIsAValid16kMonoWAV() throws {
        for passage in TranscriptionCheckPassage.allCases {
            let data = try #require(TranscriptionCheckAudio.wavData(for: passage),
                                    "undecodable bundled audio for \(passage.label)")
            let format = try #require(Self.wavFormat(data))
            #expect(format.audioFormat == 1)  // PCM
            #expect(format.channels == 1)
            #expect(format.sampleRate == 16000)
            let seconds = Double(format.dataBytes) / Double(format.sampleRate * format.channels * 2)
            #expect(seconds > 5 && seconds < 30, "duration \(seconds)s out of range for \(passage.label)")
        }
    }

    @Test func wavFileRestoreWritesAReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionAutoCheckTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TranscriptionCheckAudio.wavFileURL(for: .readingAloud, directory: directory)
        #expect(url.lastPathComponent == "passage-a.wav")
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(Double(file.length) / file.fileFormat.sampleRate > 5)
        // A second restore reuses the file and returns the same URL.
        let again = try TranscriptionCheckAudio.wavFileURL(for: .readingAloud, directory: directory)
        #expect(again == url)
    }

    private struct WAVFormat {
        let audioFormat: Int
        let channels: Int
        let sampleRate: Int
        let dataBytes: Int
    }

    /// Walks the RIFF chunks and reads the fmt/data headers.
    private static func wavFormat(_ data: Data) -> WAVFormat? {
        let bytes = [UInt8](data)
        guard bytes.count > 44,
              Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],  // "RIFF"
              Array(bytes[8..<12]) == [0x57, 0x41, 0x56, 0x45]  // "WAVE"
        else { return nil }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        var format: (Int, Int, Int)?
        var dataBytes: Int?
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = Array(bytes[offset..<offset + 4])
            let chunkSize = u32(offset + 4)
            if chunkID == [0x66, 0x6D, 0x74, 0x20] {  // "fmt "
                format = (u16(offset + 8), u16(offset + 10), u32(offset + 12))
            } else if chunkID == [0x64, 0x61, 0x74, 0x61] {  // "data"
                dataBytes = chunkSize
            }
            offset += 8 + chunkSize + (chunkSize % 2)
        }
        guard let format, let dataBytes else { return nil }
        return WAVFormat(audioFormat: format.0, channels: format.1, sampleRate: format.2, dataBytes: dataBytes)
    }
}
