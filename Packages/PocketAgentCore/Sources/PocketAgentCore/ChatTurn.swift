import Foundation

/// One plain conversation turn, persisted and later turned into model history.
public struct ChatTurn: Sendable, Equatable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}
