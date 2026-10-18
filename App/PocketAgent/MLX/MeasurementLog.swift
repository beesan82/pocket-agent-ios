import Foundation
import Observation
import UIKit

/// Device measurement notes for the MLX validation screens. Lines are fixed Japanese templates with numbers.
/// Logging never throws into the UI: file errors are ignored and the in-memory log keeps working.
@MainActor
@Observable
final class MeasurementLog {
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let at: Date
        let line: String
    }

    static let maxEntries = 500

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date

    init(
        fileURL: URL = URL.applicationSupportDirectory.appending(path: "measurement-log.txt"),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        entries = Self.load(from: fileURL)
    }

    func append(_ line: String) {
        entries.append(Entry(id: UUID(), at: now(), line: line))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func render(
        deviceInfo: String, appVersion: String, now: Date = Date(), timeZone: TimeZone = .current
    ) -> String {
        let header = [
            "# Pocket Agent 測定ログ",
            "端末: \(deviceInfo)",
            "アプリ: \(appVersion)",
            "生成: \(Self.format(now, "yyyy-MM-dd HH:mm", timeZone))",
        ]
        let body = entries.map { "[\(Self.format($0.at, "HH:mm:ss", timeZone))] \($0.line)" }
        return (header + body).joined(separator: "\n")
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // One JSON object per line, so multi-line log text survives a round trip.
    private func save() {
        let encoder = JSONEncoder()
        let text = entries.compactMap { entry in
            (try? encoder.encode(entry)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func load(from url: URL) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let loaded = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Entry.self, from: Data(line.utf8))
        }
        return Array(loaded.suffix(maxEntries))
    }
}

enum DeviceInfo {
    /// e.g. "iPhone15,4 / iOS 26.0"
    @MainActor
    static var summary: String {
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(identifier) / iOS \(UIDevice.current.systemVersion)"
    }

    /// e.g. "1.0 (7)"
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
