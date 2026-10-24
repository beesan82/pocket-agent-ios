import Foundation

/// Voice input in chat: on-device transcription (the journal's `SpeechCapture`) goes into the
/// message field, where it can be edited before sending. Nothing is sent automatically.
enum ChatVoiceInput {
    static let nothingRecognizedText = "音声を認識できませんでした。もう一度お試しください。"

    struct StopOutcome: Equatable {
        let input: String
        let message: String?
    }

    /// The field and the message after the recording ends. Text recognized before a failure (an
    /// interruption) is kept; a failure's own message is shown by the capture, so none is added.
    static func afterStop(existing: String, recognized: String, failed: Bool) -> StopOutcome {
        let merged = merge(existing: existing, recognized: recognized)
        if merged != existing || failed { return StopOutcome(input: merged, message: nil) }
        return StopOutcome(input: existing, message: nothingRecognizedText)
    }

    /// `recognized` after what was already typed (a space between them), or the field unchanged
    /// when nothing was recognized.
    static func merge(existing: String, recognized: String) -> String {
        let spoken = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return existing }
        let typed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? spoken : typed + " " + spoken
    }
}
