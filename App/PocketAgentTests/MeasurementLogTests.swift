import Foundation
import Testing
@testable import PocketAgent

@MainActor
struct MeasurementLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "measurement-log-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "measurement-log.txt")
    }

    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test func appendKeepsOrderAndCapsAt500() {
        let log = MeasurementLog(fileURL: tempURL())
        for index in 0..<510 { log.append("line \(index)") }
        #expect(log.entries.count == 500)
        #expect(log.entries.first?.line == "line 10")
        #expect(log.entries.last?.line == "line 509")
    }

    @Test func renderHasHeaderAndTimestampedLines() {
        // 2026-10-19 03:04:05 UTC = 12:04:05 in Tokyo.
        let at = Date(timeIntervalSince1970: 1_792_379_045)
        let log = MeasurementLog(fileURL: tempURL(), now: { at })
        log.append("モデル読み込み完了")
        log.append("  > 本文")
        let text = log.render(deviceInfo: "iPhone15,4 / iOS 26.0", appVersion: "1.0 (7)", now: at, timeZone: Self.tokyo)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "# Pocket Agent 測定ログ")
        #expect(lines[1] == "端末: iPhone15,4 / iOS 26.0")
        #expect(lines[2] == "アプリ: 1.0 (7)")
        #expect(lines[3] == "生成: 2026-10-19 12:04")
        #expect(lines.contains("[12:04:05] モデル読み込み完了"))
        #expect(lines.contains("[12:04:05]   > 本文"))
    }

    @Test func clearEmpties() throws {
        let url = tempURL()
        let log = MeasurementLog(fileURL: url)
        log.append("a")
        try log.clear()
        #expect(log.entries.isEmpty)
        #expect(MeasurementLog(fileURL: url).entries.isEmpty)
    }

    @Test func clearRemovesPersistedFileContent() throws {
        let url = tempURL()
        let log = MeasurementLog(fileURL: url)
        log.append("音声テストの内容")
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        try log.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func clearPreservesMemoryAndPersistedContentWhenRemovalFailsThenAllowsRetry() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var denyRemoval = true
        let log = MeasurementLog(fileURL: url, removeItem: { target in
            if denyRemoval {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: target)
        })
        log.append("音声テストの内容\n再試行まで保持する")
        let originalEntries = log.entries
        let originalData = try Data(contentsOf: url)
        #expect(MeasurementLog(fileURL: url).entries == originalEntries)

        #expect(throws: CocoaError.self) { try log.clear() }

        #expect(log.entries == originalEntries)
        #expect(try Data(contentsOf: url) == originalData)
        #expect(MeasurementLog(fileURL: url).entries == originalEntries)

        denyRemoval = false
        try log.clear()

        #expect(log.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(MeasurementLog(fileURL: url).entries.isEmpty)
    }

    @Test func clearSucceedsWhenPersistedFileIsAlreadyMissing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = MeasurementLog(fileURL: url)
        log.append("ディスク上では削除済みの記録")
        try FileManager.default.removeItem(at: url)

        try log.clear()

        #expect(log.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        try log.clear()
    }

    @Test func clearSucceedsBeforeAnyLogHasBeenWritten() throws {
        let url = tempURL()
        let log = MeasurementLog(fileURL: url)

        try log.clear()

        #expect(log.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func logFileIsExcludedFromBackup() throws {
        let url = tempURL()
        let log = MeasurementLog(fileURL: url)
        log.append("a")
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func persistsAcrossInstances() {
        let url = tempURL()
        let first = MeasurementLog(fileURL: url)
        first.append("一行目")
        first.append("複数行\n本文")
        let second = MeasurementLog(fileURL: url)
        #expect(second.entries == first.entries)
        #expect(second.entries.count == 2)
    }
}
