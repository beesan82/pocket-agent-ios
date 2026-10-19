import Foundation

/// Compact snapshot of every key measurement, rendered so one screenshot carries it all.
struct MeasurementSummary: Equatable {
    struct Sample: Equatable {
        var label: String
        var chars: Int
        var seconds: Double?
        var tokensPerSecond: Double?
        var title: String?
    }

    static let maxLineLength = 40

    var device: String
    var appVersion: String
    var modelName: String
    var modelStatus: String
    var loadSeconds: Double?
    var memoryBeforeMB: Int?
    var memoryAfterMB: Int?
    var availableMB: Int?
    var samples: [Sample]
    var speechStatus: String
    var speechChars: Int?

    var lines: [String] {
        let missing = "未測定"
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f 秒", $0) } ?? missing }
        func megabytes(_ value: Int?) -> String { value.map { "\($0) MB" } ?? missing }
        var result = [
            "端末 \(device)",
            "アプリ \(appVersion)",
            "モデル \(modelName)",
            "状態 \(modelStatus)",
            "読み込み \(seconds(loadSeconds))",
            "メモリ 読込前 \(megabytes(memoryBeforeMB))",
            "メモリ 読込後 \(megabytes(memoryAfterMB))",
            "利用可能 \(megabytes(availableMB))",
        ]
        for sample in samples {
            result.append(sampleLine(sample))
        }
        result.append("音声 \(speechStatus)")
        result.append("音声30秒 \(speechChars.map { "\($0)字" } ?? missing)")
        return result.map(Self.clipped)
    }

    private func sampleLine(_ sample: Sample) -> String {
        let head = "\(sample.label) \(sample.chars)字"
        guard let seconds = sample.seconds else { return head + " 未測定" }
        let rate = sample.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "tok/s 未測定"
        var line = head + String(format: " %.1f 秒 ", seconds) + rate
        if let title = sample.title, !title.isEmpty {
            line += " 見出し: "
            let room = Self.maxLineLength - line.count
            if title.count <= room {
                line += title
            } else if room > 0 {
                line += String(title.prefix(room - 1)) + "…"
            }
        }
        return line
    }

    private static func clipped(_ line: String) -> String {
        line.count <= maxLineLength ? line : String(line.prefix(maxLineLength - 1)) + "…"
    }
}
