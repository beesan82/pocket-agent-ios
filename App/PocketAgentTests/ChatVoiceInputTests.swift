import Testing
@testable import PocketAgent

/// Voice input in chat (2026-10-24): what was recognized goes into the message field for editing.
struct ChatVoiceInputTests {
    @Test func recognizedTextFillsAnEmptyField() {
        #expect(ChatVoiceInput.merge(existing: "", recognized: "ポチの散歩はいつ？") == "ポチの散歩はいつ？")
    }

    @Test func recognizedTextIsAppendedAfterTypedText() {
        #expect(ChatVoiceInput.merge(existing: "メモ:", recognized: "牛乳を買う") == "メモ: 牛乳を買う")
        #expect(ChatVoiceInput.merge(existing: "メモ: ", recognized: "牛乳を買う") == "メモ: 牛乳を買う")
    }

    @Test func blankRecognitionKeepsTheField() {
        #expect(ChatVoiceInput.merge(existing: "途中", recognized: "  \n") == "途中")
    }
}
