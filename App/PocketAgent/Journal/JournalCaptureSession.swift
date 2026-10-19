import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// RED stub.
@MainActor
@Observable
final class JournalCaptureSession {
    enum Phase: Equatable {
        case editing, summarizing, summarized, saving, saved, failed(String)
    }

    var transcript = ""
    var summaryBody = ""
    var summaryTitle = ""
    private(set) var phase: Phase = .editing
    @ObservationIgnored private(set) var summaryTask: Task<Void, Never>?

    init(source: JournalEntry.Source, store: any JournalStore, assistant: (any JournalAssisting)?, modelReady: Bool) {}

    func beginIfNeeded() { phase = .summarizing }
    func stopSummary() {}
    func save(useTranscriptOnly: Bool) async {}
}
