import PocketAgentCore

/// What a live transcription reports while it runs.
enum TranscriptEvent: Sendable, Equatable {
    /// The latest tentative text (replaced as recognition improves).
    case volatile(String)
    /// One final result; the unit for notes and (later) translation.
    case final(TranscriptSegment)
    /// The capture ended on its own with a fixed user-facing message; what was recognized stays valid.
    case failed(String)
}

/// A live on-device transcription the meeting session can start, stop and listen to.
/// `SpeechCapture` is the real one; tests substitute a fake.
@MainActor
protocol TranscriptSource: AnyObject {
    var reason: SpeechUnavailableReason? { get }
    func refreshAvailability() async
    func requestPermissions() async
    func installAssets() async throws
    /// Starts recording and returns this capture's events; the stream ends when the capture stops or fails.
    func start() async throws -> AsyncStream<TranscriptEvent>
    func stop() async
}
