import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

@MainActor
struct JournalModelAccessTests {
    private let first = MLXModelRegistry.all[0]
    private let second = MLXModelRegistry.all[1]

    private func makeStoreAndRuntime() -> (MLXModelStore, MLXRuntime) {
        let name = "JournalModelAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = MLXModelStore(
            downloader: FakeDownloader(downloaded: Set(MLXModelRegistry.all.map(\.id))),
            baseDirectory: FileManager.default.temporaryDirectory.appending(path: "JournalModelAccessTests"),
            defaults: defaults)
        return (store, MLXRuntime(store: store, loader: FakeLoader(), notificationCenter: NotificationCenter()))
    }

    // Choosing another downloaded model in Settings must not keep serving the old loaded one.
    @Test func readyClientIsNilWhenAnotherModelIsSelected() async {
        let (store, runtime) = makeStoreAndRuntime()
        store.selected = first
        await runtime.load(first)
        #expect(JournalModelAccess.readyClient(store: store, runtime: runtime) != nil)

        store.selected = second

        #expect(JournalModelAccess.readyClient(store: store, runtime: runtime) == nil)
    }

    @Test func deletingTheLoadedModelUnloadsIt() async {
        let (store, runtime) = makeStoreAndRuntime()
        await runtime.load(first)

        runtime.modelDeleted(first)

        #expect(runtime.client == nil)
        #expect(runtime.loadedModelID == nil)
        #expect(runtime.state == .idle)
    }

    @Test func deletingAnotherModelKeepsTheLoadedOne() async {
        let (_, runtime) = makeStoreAndRuntime()
        await runtime.load(first)

        runtime.modelDeleted(second)

        #expect(runtime.client != nil)
        #expect(runtime.state == .loaded)
    }

    private func makeSettings() -> ModelSettings {
        let name = "JournalModelAccessTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ModelSettings(defaults: defaults)
    }

    // User decision 2026-10-22: the journal follows the on-device choice in Settings, never Claude.
    @Test func backendFollowsTheOnDeviceChoice() {
        let settings = makeSettings()
        let usable = FixedAvailability(reason: nil)
        let unusable = FixedAvailability(reason: .deviceNotEligible)

        settings.choice = .appleLocal
        #expect(JournalModelAccess.backend(settings: settings, availability: usable) == .appleLocal)
        #expect(JournalModelAccess.backend(settings: settings, availability: unusable) == .mlxLocal)
        settings.choice = .claude
        #expect(JournalModelAccess.backend(settings: settings, availability: usable) == .mlxLocal)
        settings.choice = .mlxLocal
        #expect(JournalModelAccess.backend(settings: settings, availability: usable) == .mlxLocal)
    }

    // Apple needs no download and no load: ready at once, and the MLX runtime is never touched.
    @Test func appleBackendIsReadyWithoutLoading() async throws {
        let (store, runtime) = makeStoreAndRuntime()

        #expect(JournalModelAccess.reason(.appleLocal, store: store, runtime: runtime) == nil)
        let ready = try #require(JournalModelAccess.readyClient(.appleLocal, store: store, runtime: runtime))
        #expect(ready.providerIdentifier == .foundationModels)
        let loaded = await JournalModelAccess.client(.appleLocal, store: store, runtime: runtime)
        let client = try #require(loaded)
        #expect(client.providerIdentifier == .foundationModels)
        #expect(runtime.state == .idle)
        #expect(runtime.loadedModelID == nil)
    }

    @Test func mlxBackendKeepsTheDownloadedModelPath() async {
        let (store, runtime) = makeStoreAndRuntime()
        store.selected = first

        #expect(JournalModelAccess.reason(.mlxLocal, store: store, runtime: runtime)
            == JournalModelAccess.reason(store: store, runtime: runtime))
        #expect(JournalModelAccess.readyClient(.mlxLocal, store: store, runtime: runtime) == nil)
        await runtime.load(first)
        #expect(JournalModelAccess.readyClient(.mlxLocal, store: store, runtime: runtime)?.providerIdentifier
            != .foundationModels)
        #expect(JournalModelAccess.readyClient(.mlxLocal, store: store, runtime: runtime) != nil)
    }
}
