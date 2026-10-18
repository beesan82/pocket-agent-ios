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
    private let gated: Bool
    private let gate = TestGate()
    private var _loads: [String] = []
    private var _directories: [URL] = []
    private var _releases = 0

    /// `gated`: each load waits for `release()` and ignores cancellation (like a long MLX load).
    init(fails: Bool = false, gated: Bool = false) {
        self.fails = fails
        self.gated = gated
    }

    var loads: [String] { lock.withLock { _loads } }
    var directories: [URL] { lock.withLock { _directories } }
    var releases: Int { lock.withLock { _releases } }

    func release() { gate.open() }

    func load(_ model: MLXModelInfo, directory: URL) async throws -> any LLMClient {
        lock.withLock {
            _loads.append(model.id)
            _directories.append(directory)
        }
        if gated {
            await gate.wait()
        } else {
            try await Task.sleep(for: .milliseconds(20))
        }
        if fails { throw FakeError.failed }
        return FakeLLMClient([])
    }

    func releaseMemory() { lock.withLock { _releases += 1 } }
}

@MainActor
struct MLXRuntimeTests {
    private let model = MLXModelRegistry.default
    private let base = FileManager.default.temporaryDirectory.appending(path: "MLXRuntimeTests")

    private func makeRuntime(
        _ loader: FakeLoader, center: NotificationCenter = NotificationCenter()
    ) -> MLXRuntime {
        let name = "MLXRuntimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = MLXModelStore(
            downloader: FakeDownloader(downloaded: [model.id]),
            baseDirectory: base,
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

    @Test func loadUsesLocalModelDirectory() async {
        let loader = FakeLoader()
        let runtime = makeRuntime(loader)

        await runtime.load(model)

        #expect(loader.directories == [HubModelDownloader.directory(of: model, at: base)])
    }

    @Test func concurrentLoadsOfSameModelLoadOnce() async throws {
        let loader = FakeLoader(gated: true)
        let runtime = makeRuntime(loader)

        async let first: Void = runtime.load(model)
        async let second: Void = runtime.load(model)
        #expect(try await waitUntil { !loader.loads.isEmpty && runtime.state == .loading })
        try await Task.sleep(for: .milliseconds(50))
        loader.release()
        _ = await (first, second)

        #expect(loader.loads.count == 1)
        #expect(runtime.state == .loaded)
        #expect(runtime.client != nil)
    }

    @Test func memoryWarningDuringLoadingDiscardsLateResult() async throws {
        let center = NotificationCenter()
        let loader = FakeLoader(gated: true)
        let runtime = makeRuntime(loader, center: center)
        let model = model

        let loading = Task { await runtime.load(model) }
        #expect(try await waitUntil { runtime.state == .loading && !loader.loads.isEmpty })
        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        #expect(runtime.state == .unloadedForMemory)
        #expect(runtime.client == nil)

        // The load finishes anyway: its result is dropped and its memory released.
        loader.release()
        await loading.value
        #expect(runtime.state == .unloadedForMemory)
        #expect(runtime.client == nil)
        #expect(loader.releases == 1)
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
            _ = try await MLXModelLoader().load(model, directory: FileManager.default.temporaryDirectory)
        }
        #endif
    }

    /// Polls on the main actor; returns false on timeout instead of hanging the suite.
    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
