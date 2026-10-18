import Foundation
import PocketAgentCore
import Security

// RED stub
struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "" }
}

struct KeychainCredentialStore: CredentialStore {
    let service: String
    let account: String

    init(service: String = "com.example.pocketagent.anthropic", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    func readAPIKey() throws -> String? { "wrong" }
    func saveAPIKey(_: String) throws {}
    func deleteAPIKey() throws { throw KeychainError(status: errSecParam) }
}
