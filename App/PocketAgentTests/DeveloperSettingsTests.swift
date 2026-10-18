import Foundation
import Testing
@testable import PocketAgent

@MainActor
struct DeveloperSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "DeveloperSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaults() {
        let settings = DeveloperSettings(defaults: makeDefaults())

        #expect(settings.isEnabled == false)
        #expect(settings.repository == "beesan82/pocket-agent-measurements")
    }

    @Test func valuesPersist() {
        let defaults = makeDefaults()
        let settings = DeveloperSettings(defaults: defaults)

        settings.isEnabled = true
        settings.repository = "someone/other.repo"
        let reloaded = DeveloperSettings(defaults: defaults)

        #expect(reloaded.isEnabled)
        #expect(reloaded.repository == "someone/other.repo")
    }

    @Test func validRepositories() {
        for value in ["owner/name", "a/b", "beesan82/pocket-agent-measurements", "my_org/repo.name-1"] {
            #expect(DeveloperSettings.isValidRepository(value), "\(value)")
        }
    }

    @Test func invalidRepositories() {
        let values = [
            "", "owner", "owner/", "/name", "owner/name/extra", "own er/name", "owner/na me",
            "owner/名前", "owner/../x", "../name", "owner/..", "./name", "owner/.", "owner/name?x=1",
            "owner/name\n", " owner/name",
        ]
        for value in values {
            #expect(!DeveloperSettings.isValidRepository(value), "\(value)")
        }
    }
}
