import Foundation
import SwiftData

// RED stub: signature only.
enum NoteMigration {
    static let flagKey = "pocketagent.notesMigrated"

    @MainActor
    static func migrateOnce(context: ModelContext, defaults: UserDefaults) throws {}
}
