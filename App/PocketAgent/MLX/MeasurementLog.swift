import Foundation
import Observation

/// Stub (RED): behaviour is added in the next commit.
@MainActor
@Observable
final class MeasurementLog {
    struct Entry: Identifiable, Equatable, Codable {
        let id: UUID
        let at: Date
        let line: String
    }

    private(set) var entries: [Entry] = []

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {}

    func append(_ line: String) {}

    func clear() {}

    func render(deviceInfo: String, appVersion: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        ""
    }
}
