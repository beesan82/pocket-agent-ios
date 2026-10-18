import AgentRunKit
import Foundation

// RED stub: signatures only. Behaviour is deliberately wrong.
public enum LLMErrorDescriber {
    public static func userMessage(for error: any Error) -> String {
        String(describing: error)
    }
}
