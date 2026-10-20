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
}
