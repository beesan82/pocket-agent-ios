import Foundation
import SwiftData

@Model
final class NoteRecord {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelChoiceRaw: String
    @Relationship(deleteRule: .cascade, inverse: \TurnRecord.conversation)
    var turns: [TurnRecord] = []

    init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date, modelChoiceRaw: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelChoiceRaw = modelChoiceRaw
    }
}

@Model
final class TurnRecord {
    var roleRaw: String
    var text: String
    var createdAt: Date
    var order: Int
    var conversation: ConversationRecord?

    init(roleRaw: String, text: String, createdAt: Date, order: Int) {
        self.roleRaw = roleRaw
        self.text = text
        self.createdAt = createdAt
        self.order = order
    }
}

enum AppModelContainer {
    /// `url` places the store somewhere else than the default location (tests).
    static func make(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PocketAgentSchemaV2.self)
        let configuration = if let url {
            ModelConfiguration(schema: schema, url: url)
        } else {
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        let container = try ModelContainer(
            for: schema, migrationPlan: PocketAgentMigrationPlan.self, configurations: [configuration])
        if !inMemory {
            // The store holds every conversation, memo, journal entry and meeting transcript.
            // Applied on every launch, after the container has opened (and so created) the files.
            // Best effort, like the other stores: a failure here must not keep the data from opening.
            try? StoreFileGuard.protect(storeAt: configuration.url)
        }
        return container
    }
}

/// Keeps the SwiftData store on this device (ADR-053): excluded from iCloud / computer backups,
/// and encrypted while the device is locked.
enum StoreFileGuard {
    /// SQLite keeps the newest writes in the `-wal` file, with `-shm` as its index.
    static let sidecarSuffixes = ["", "-wal", "-shm"]
    /// `completeUnlessOpen`, not `complete`: the store stays open while a meeting is recorded
    /// with the phone locked (ADR-034) and must remain writable through the handles it already has.
    static let protection = FileProtectionType.completeUnlessOpen

    /// The store file and its SQLite sidecars, whether or not they exist yet.
    static func files(ofStoreAt storeURL: URL) -> [URL] {
        sidecarSuffixes.map { URL(fileURLWithPath: storeURL.path(percentEncoded: false) + $0) }
    }

    /// Marks every existing store file; a missing sidecar is skipped. Throws the first failure
    /// after trying all files.
    static func protect(storeAt storeURL: URL, fileManager: FileManager = .default) throws {
        var firstError: (any Error)?
        for file in files(ofStoreAt: storeURL) {
            let path = file.path(percentEncoded: false)
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                var url = file
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
                try fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: path)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}
