import Foundation
import PocketAgentCore
import SwiftData
import Testing
@testable import PocketAgent

/// ADR-053: the SwiftData store (conversations, memos, journal, meeting transcripts) is kept out
/// of device backups. The file-protection class is set by the same call but is not asserted here:
/// the simulator does not enforce data protection, so only a real device can confirm it.
@MainActor
struct StoreFileGuardTests {
    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "store-guard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isExcluded(_ url: URL) throws -> Bool? {
        // A fresh URL value: resource values are cached per URL instance.
        try URL(fileURLWithPath: url.path(percentEncoded: false))
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    @Test func filesAreTheStoreAndItsSQLiteSidecars() {
        let store = URL(fileURLWithPath: "/tmp/x/default.store")

        #expect(StoreFileGuard.files(ofStoreAt: store).map(\.lastPathComponent)
            == ["default.store", "default.store-wal", "default.store-shm"])
    }

    @Test func protectExcludesStoreAndSidecarsFromBackup() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        let files = StoreFileGuard.files(ofStoreAt: store)
        for file in files { try Data("x".utf8).write(to: file) }
        for file in files { #expect(try isExcluded(file) != true) }

        try StoreFileGuard.protect(storeAt: store)

        for file in files { #expect(try isExcluded(file) == true) }
    }

    @Test func protectSkipsMissingSidecars() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "default.store")
        try Data("x".utf8).write(to: store)

        try StoreFileGuard.protect(storeAt: store)

        #expect(try isExcluded(store) == true)
        #expect(!FileManager.default.fileExists(atPath: store.path(percentEncoded: false) + "-wal"))
        // Nothing to protect yet (first launch before the store exists) is not an error.
        try StoreFileGuard.protect(storeAt: directory.appending(path: "absent.store"))
    }

    /// The real path: opening the on-disk container marks every store file SQLite created.
    @Test func openingTheOnDiskContainerExcludesItsFilesFromBackup() throws {
        // Not removed afterwards: unlinking a store that SQLite still has open is reported as a fault.
        let directory = try tempDirectory()
        let store = directory.appending(path: "default.store")

        let container = try AppModelContainer.make(url: store)
        let repository = ConversationRepository(context: container.mainContext)
        _ = try repository.create(choice: .mlxLocal)

        let existing = StoreFileGuard.files(ofStoreAt: store).filter {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        #expect(existing.contains { $0.lastPathComponent == "default.store" })
        for file in existing { #expect(try isExcluded(file) == true) }
    }

    @Test func protectionClassKeepsTheStoreWritableWhileLocked() {
        // ADR-034: a meeting keeps recording with the phone locked, so `.complete` would break saving.
        #expect(StoreFileGuard.protection == .completeUnlessOpen)
    }
}
