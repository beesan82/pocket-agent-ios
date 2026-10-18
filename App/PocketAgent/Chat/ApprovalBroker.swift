import Foundation
import Observation
import PocketAgentCore

/// What the approval sheet shows: the request plus a human-readable summary.
struct PendingApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let approval: PendingApproval
    let summary: String
}

/// Bridges tool approval requests (from any task) to the approval sheet.
///
/// Requests are shown one at a time: a second `ask` waits until the first is answered,
/// so a continuation is never overwritten. Every continuation is resumed exactly once:
/// by `answer`, or with `.deny(reason: nil)` when the asking task is cancelled.
@MainActor
@Observable
final class ApprovalBroker {
    private(set) var pending: PendingApprovalRequest?

    private struct Active {
        let id: UUID
        let continuation: CheckedContinuation<UserApprovalDecision, Never>
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var waiters: [Waiter] = []

    func ask(_ request: PendingApproval, summary: String) async -> UserApprovalDecision {
        while active != nil {
            await waitForSlot()
            if Task.isCancelled {
                wakeNextWaiterIfIdle()
                return .deny(reason: nil)
            }
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                active = Active(id: id, continuation: continuation)
                pending = PendingApprovalRequest(id: id, approval: request, summary: summary)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, with: .deny(reason: nil)) }
        }
    }

    /// No-op when nothing is pending.
    func answer(_ decision: UserApprovalDecision) {
        guard let active else { return }
        resolve(id: active.id, with: decision)
    }

    /// Denies the request identified by `id`; no-op if it was already answered or another is active.
    func deny(id: UUID) {
        resolve(id: id, with: .deny(reason: nil))
    }

    /// Resumes the active request only if it is still the one identified by `id`.
    private func resolve(id: UUID, with decision: UserApprovalDecision) {
        guard let current = active, current.id == id else { return }
        active = nil
        pending = nil
        current.continuation.resume(returning: decision)
        wakeNextWaiterIfIdle()
    }

    private func waitForSlot() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseWaiter(id: id) }
        }
    }

    private func releaseWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    private func wakeNextWaiterIfIdle() {
        guard active == nil, !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }
}
