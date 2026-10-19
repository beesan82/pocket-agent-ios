import Foundation
import Observation
import PocketAgentCore
import PocketAgentRuntime

/// "Ask the journal": one question at a time, answer streamed in, evidence listed.
@MainActor
@Observable
final class AskSession {
    enum Phase: Equatable {
        case idle, searching, answering, done, stopped, failed(String)
    }

    static let failedText = "回答を作成できませんでした。もう一度お試しください。"

    private(set) var answer = ""
    private(set) var evidence: [PackedEntry] = []
    private(set) var usedRecentFallback = false
    private(set) var phase: Phase = .idle

    /// Set by the screen from the currently loaded model right before `ask`.
    @ObservationIgnored var assistant: (any JournalAssisting)?
    @ObservationIgnored private(set) var askTask: Task<Void, Never>?

    @ObservationIgnored private let store: any JournalStore
    @ObservationIgnored private var generation = 0

    init(store: any JournalStore, assistant: (any JournalAssisting)?) {
        self.store = store
        self.assistant = assistant
    }

    var isRunning: Bool { phase == .searching || phase == .answering }

    /// Replaces any running question.
    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let assistant else { return }
        askTask?.cancel()
        generation += 1
        let current = generation
        answer = ""
        evidence = []
        usedRecentFallback = false
        phase = .searching
        let store = store
        askTask = Task { [weak self] in
            do {
                let result = try await assistant.ask(trimmed, store: store)
                // `ask` already started generating, so the answer is always iterated: when this task
                // is cancelled the loop ends at once and the stream's termination stops the model.
                if let self, current == self.generation, !Task.isCancelled {
                    self.evidence = result.evidence
                    self.usedRecentFallback = result.usedRecentFallback
                    self.phase = .answering
                }
                for try await chunk in result.answer {
                    guard let self else { return }
                    if current == self.generation { self.answer += chunk }
                }
                guard let self, current == self.generation, !Task.isCancelled else { return }
                self.askTask = nil
                self.phase = .done
            } catch {
                guard let self, current == self.generation, !Task.isCancelled else { return }
                self.askTask = nil
                self.phase = .failed(Self.failedText)
            }
        }
    }

    /// Cancels the running question; what has been answered so far stays on screen.
    func stop() {
        generation += 1
        askTask?.cancel()
        askTask = nil
        if isRunning { phase = answer.isEmpty ? .idle : .done }
    }
}
