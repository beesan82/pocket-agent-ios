import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// RED stub.
@MainActor
@Observable
final class AskSession {
    enum Phase: Equatable {
        case idle, searching, answering, done, failed(String)
    }

    private(set) var answer = ""
    private(set) var evidence: [PackedEntry] = []
    private(set) var usedRecentFallback = false
    private(set) var phase: Phase = .idle
    @ObservationIgnored var assistant: (any JournalAssisting)?
    @ObservationIgnored private(set) var askTask: Task<Void, Never>?

    init(store: any JournalStore, assistant: (any JournalAssisting)?) {}

    func ask(_ question: String) {}
    func stop() {}
}
