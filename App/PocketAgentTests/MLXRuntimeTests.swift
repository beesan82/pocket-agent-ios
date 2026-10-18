import AgentRunKit
import Foundation
import PocketAgentCore
import Testing
import UIKit
@testable import PocketAgent

final class FakeLoader: ModelLoading, @unchecked Sendable {
    enum FakeError: Error { case failed }

    private let lock = NSLock()
    private let fails: Bool
    private var _loads: [String] = []
    private var _releases = 0

    init(fails: Bool = false) { self.fails = fails }

    var loads: [String] { lock.withLock { _loads } }
    var releases: Int { lock.withLock { _releases } }

    func load(_ model: MLXModelInfo, from _: URL) async throws -> any LLMClient {
        lock.withLock { _loads.append(model.id) }
        try await Task.sleep(for: .milliseconds(20))
        if fails { throw FakeError.failed }
        return FakeLLMClient([])
    }

    func releaseMemory() { lock.withLock { _releases += 1 } }
}

@MainActor
struct MLXRuntimeTests {
    private let model = MLXModelRegistry.default

    private func makeRuntime(
        _ loader: FakeLoader, center: NotificationCenter = NotificationCenter()
    ) -> MLXRuntime {
        let name = "MLXRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = MLXModelStore(
            downloader: FakeDownloader(downloaded: [model.id]),
            baseDirectory: FileManager.default.temporaryDirectory.appending(path: "MLXRuntimeTests"),
            defaults: defaults)
        return MLXRuntime(store: store, loader: loader, notificationCenter: center)
    }

    @Test func loadSetsClientAndSeconds() async throws {
        let loader = FakeLoader()
        let runtime = makeRuntime(loader)
        #expect(runtime.state == .idle)

        await runtime.load(model)

        #expect(runtime.state == .loaded)
        #expect(runtime.client != nil)
        #expect(runtime.loadedModelID == model.id)
        let seconds = try #require(runtime.lastLoadSeconds)
        #expect(seconds >= 0.01)
        #expect(loader.loads == [model.id])

        // Loading the same model again is a no-op.
        await runtime.load(model)
        #expect(loader.loads == [model.id])
    }

    @Test func loadFailureShowsFixedTextAndNoClient() async {
        let runtime = makeRuntime(FakeLoader(fails: true))

        await runtime.load(model)

        #expect(runtime.state == .failed(MLXRuntime.loadFailedText))
        #expect(runtime.client == nil)
    }

    @Test func unloadDropsClientAndReleasesMemory() async {
        let loader = FakeLoader()
        let runtime = makeRuntime(loader)
        await runtime.load(model)

        runtime.unload()

        #expect(runtime.state == .idle)
        #expect(runtime.client == nil)
        #expect(loader.releases == 1)
    }

    @Test func memoryWarningUnloadsAndExplains() async {
        let center = NotificationCenter()
        let loader = FakeLoader()
        let runtime = makeRuntime(loader, center: center)
        await runtime.load(model)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        #expect(runtime.state == .unloadedForMemory)
        #expect(runtime.client == nil)
        #expect(loader.releases == 1)
        #expect(MLXAvailability.deviceReason(state: runtime.state, status: .downloaded) == .unloadedForMemory)
        #if targetEnvironment(simulator)
        #expect(MLXAvailability.reason(state: runtime.state, status: .downloaded) == .simulatorUnsupported)
        #else
        #expect(MLXAvailability.reason(state: runtime.state, status: .downloaded) == .unloadedForMemory)
        #endif
    }

    @Test func memoryWarningWhileIdleChangesNothing() {
        let center = NotificationCenter()
        let runtime = makeRuntime(FakeLoader(), center: center)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        #expect(runtime.state == .idle)
    }

    @Test func deviceReasonMapping() {
        #expect(MLXAvailability.deviceReason(state: .loaded, status: .downloaded) == nil)
        #expect(MLXAvailability.deviceReason(state: .loading, status: .downloaded) == .modelLoading)
        #expect(MLXAvailability.deviceReason(state: .unloadedForMemory, status: .downloaded) == .unloadedForMemory)
        #expect(MLXAvailability.deviceReason(state: .idle, status: .notDownloaded) == .modelNotDownloaded)
        #expect(MLXAvailability.deviceReason(state: .idle, status: .downloading(0.3)) == .modelNotDownloaded)
        #expect(MLXAvailability.deviceReason(state: .failed("x"), status: .failed("y")) == .modelNotDownloaded)
        // Downloaded but not loaded: callers load() first.
        #expect(MLXAvailability.deviceReason(state: .idle, status: .downloaded) == nil)
    }

    @Test func simulatorReasonWinsOnSimulator() {
        #if targetEnvironment(simulator)
        #expect(MLXAvailability.reason(state: .loaded, status: .downloaded) == .simulatorUnsupported)
        #expect(MLXAvailability.reason(state: .idle, status: .notDownloaded) == .simulatorUnsupported)
        #endif
    }

    @Test func realLoaderThrowsOnSimulator() async {
        #if targetEnvironment(simulator)
        let model = model
        await #expect(throws: MLXUnsupportedOnSimulator.self) {
            _ = try await MLXModelLoader().load(model, from: FileManager.default.temporaryDirectory)
        }
        #endif
    }
}
