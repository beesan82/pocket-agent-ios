import Foundation

/// Voice input in chat: on-device transcription (the journal's `SpeechCapture`) goes into the
/// message field, where it can be edited before sending. Nothing is sent automatically.
enum ChatVoiceInput {
    static let nothingRecognizedText = "音声を認識できませんでした。もう一度お試しください。"

    /// `recognized` after what was already typed (a space between them), or the field unchanged
    /// when nothing was recognized.
    static func merge(existing: String, recognized: String) -> String {
        let spoken = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return existing }
        let typed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? spoken : typed + " " + spoken
    }
}
