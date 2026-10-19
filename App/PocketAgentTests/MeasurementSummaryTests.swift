import Testing
@testable import PocketAgent

struct MeasurementSummaryTests {
    private func empty() -> MeasurementSummary {
        MeasurementSummary(
            device: "iPhone15,4 / iOS 26.0", appVersion: "1.0 (7)", modelName: "テストモデル",
            modelStatus: "未読み込み", loadSeconds: nil, memoryBeforeMB: nil, memoryAfterMB: nil,
            availableMB: nil,
            samples: [.init(label: "短文", chars: 60, seconds: nil, tokensPerSecond: nil, title: nil)],
            speechStatus: "利用可能", speechChars: nil)
    }

    private func full(title: String = "旅行の計画") -> MeasurementSummary {
        var summary = empty()
        summary.modelStatus = "読み込み済み"
        summary.loadSeconds = 12.34
        summary.memoryBeforeMB = 812
        summary.memoryAfterMB = 2301
        summary.availableMB = 1500
        summary.samples = [
            .init(label: "短文", chars: 60, seconds: 4.14, tokensPerSecond: 18.23, title: title),
            .init(label: "中文", chars: 300, seconds: 9.0, tokensPerSecond: 17.0, title: title),
            .init(label: "長文", chars: 1200, seconds: 30.55, tokensPerSecond: 15.5, title: title),
        ]
        summary.speechChars = 120
        return summary
    }

    @Test func unmeasuredValuesShowPlaceholder() {
        let lines = empty().lines
        #expect(lines.contains("読み込み 未測定"))
        #expect(lines.contains("短文 60字 未測定"))
        #expect(lines.contains("メモリ 読込前 未測定"))
        #expect(lines.contains("メモリ 読込後 未測定"))
        #expect(lines.contains("利用可能 未測定"))
        #expect(lines.contains("音声30秒 未測定"))
    }

    @Test func formatsNumbersWithUnits() {
        let lines = full().lines
        #expect(lines.contains("読み込み 12.3 秒"))
        #expect(lines.contains("メモリ 読込前 812 MB"))
        #expect(lines.contains("メモリ 読込後 2301 MB"))
        #expect(lines.contains("利用可能 1500 MB"))
        #expect(lines.contains("短文 60字 4.1 秒 18.2 tok/s 見出し: 旅行の計画"))
        #expect(lines.contains("音声30秒 120字"))
    }

    @Test func longTitleIsTruncated() {
        let lines = full(title: String(repeating: "あ", count: 50)).lines
        let line = lines.first { $0.hasPrefix("短文") }
        #expect(line != nil)
        #expect(line?.count == 40)
        #expect(line?.hasSuffix("…") == true)
        #expect(lines.allSatisfy { $0.count <= 40 })
    }

    @Test func lineCountFitsOneScreen() {
        #expect(full().lines.count <= 14)
        #expect(full().lines.count >= 10)
    }
}
