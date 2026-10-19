import Foundation

/// Per conversation and per model: decides when a model is shown as "cannot handle notes" (requirements §6.4).
public struct ToolCapabilityTracker: Sendable, Equatable {
    public static let rescueThreshold = 2
    public static let missedIntentThreshold = 2
    public static let memoryIntentKeywords = ["覚えて", "保存", "メモ", "消して", "直して"]
    public static let limitedMessage =
        "このモデルはメモの保存・編集を安定して扱えません。文章生成のみ使えます。Claude に切り替えると使えます。"

    private var rescues = 0
    private var missedIntents = 0

    public init() {}

    public var isLimited: Bool {
        rescues >= Self.rescueThreshold || missedIntents >= Self.missedIntentThreshold
    }

    /// A native tool call is the expected path; it neither counts against nor clears earlier evidence.
    public mutating func recordNativeToolCall() {}

    /// The model wrote a tool call as JSON in its reply instead of calling the tool.
    public mutating func recordRescue() {
        rescues += 1
    }

    /// A turn that ended with no tool call at all (native or rescued).
    public mutating func recordNoToolCall(userMessage: String) {
        if Self.hasMemoryIntent(userMessage) {
            missedIntents += 1
        }
    }

    public mutating func reset() {
        rescues = 0
        missedIntents = 0
    }

    public static func hasMemoryIntent(_ text: String) -> Bool {
        memoryIntentKeywords.contains { text.contains($0) }
    }
}
