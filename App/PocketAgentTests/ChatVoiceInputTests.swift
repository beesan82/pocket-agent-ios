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

/// After the recording stops (normally or because it failed, e.g. an interruption).
struct ChatVoiceInputStopTests {
    @Test func stoppedWithTextFillsTheField() {
        #expect(ChatVoiceInput.afterStop(existing: "", recognized: "ポチの散歩", failed: false)
            == .init(input: "ポチの散歩", message: nil))
    }

    @Test func stoppedWithNothingExplains() {
        #expect(ChatVoiceInput.afterStop(existing: "途中", recognized: " ", failed: false)
            == .init(input: "途中", message: ChatVoiceInput.nothingRecognizedText))
    }

    // Review 2026-10-24: what was recognized before an interruption is kept, not thrown away.
    @Test func failedAfterPartialRecognitionKeepsTheText() {
        #expect(ChatVoiceInput.afterStop(existing: "", recognized: "ポチの散", failed: true)
            == .init(input: "ポチの散", message: nil))
    }

    // The failure itself is shown by the capture's state; no second message.
    @Test func failedWithNothingAddsNoMessage() {
        #expect(ChatVoiceInput.afterStop(existing: "途中", recognized: "", failed: true)
            == .init(input: "途中", message: nil))
    }
}
