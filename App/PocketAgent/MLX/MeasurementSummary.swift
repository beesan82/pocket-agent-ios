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

    var lines: [String] { [] }
}
