import AgentRunKit
import Foundation
import PocketAgentCore

/// Text-only chat turn for the on-device model: no tools, no agent loop.
public enum LocalChat {
    /// System (prompt + memory section), then trimmed history, then the current message.
    public static func messages(memorySection: String?, history: [ChatTurn], message: String) -> [ChatMessage] {
        let system = ConversationContext.localChatSystemPrompt + (memorySection.map { "\n\n" + $0 } ?? "")
        return [.system(system)]
            + ConversationContext.history(from: history, budget: .mlxLocal)
            + [.user(message)]
    }

    /// Content deltas only. Cancelling the consumer cancels the upstream model call.
    public static func stream(
        client: any LLMClient, messages: [ChatMessage], maxTokens: Int = 512
    ) -> AsyncThrowingStream<String, Error> {
        StreamBridge.contentOnly(client.stream(
            messages: messages, tools: [], requestContext: LocalGeneration.requestContext(maxTokens: maxTokens)
        ))
    }
}
