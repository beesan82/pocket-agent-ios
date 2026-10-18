import Foundation
import PocketAgentCore
import Security
import Testing
@testable import PocketAgent

@Suite(.serialized)
struct KeychainCredentialStoreTests {
    private func makeStore() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "com.example.pocketagent.tests.\(UUID().uuidString)")
    }

    @Test func saveReadOverwriteDelete() throws {
        let store = makeStore()
        defer { try? store.deleteAPIKey() }

        #expect(try store.readAPIKey() == nil)
        try store.saveAPIKey("test-key-1")
        #expect(try store.readAPIKey() == "test-key-1")
        try store.saveAPIKey("test-key-2")
        #expect(try store.readAPIKey() == "test-key-2")
        try store.deleteAPIKey()
        #expect(try store.readAPIKey() == nil)
    }

    @Test func deletingMissingKeyIsNotAnError() throws {
        try makeStore().deleteAPIKey()
    }

    @Test func storesAreIsolatedByService() throws {
        let first = makeStore(), second = makeStore()
        defer {
            try? first.deleteAPIKey()
            try? second.deleteAPIKey()
        }

        try first.saveAPIKey("test-key-1")

        #expect(try second.readAPIKey() == nil)
    }

    @Test func errorDescriptionCarriesOnlyStatus() {
        let error = KeychainError(status: errSecInteractionNotAllowed)
        #expect(error.status == errSecInteractionNotAllowed)
        #expect(String(describing: error).contains("\(errSecInteractionNotAllowed)"))
    }
}
