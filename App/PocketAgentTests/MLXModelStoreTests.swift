import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

/// Scripted downloader: reports `steps`, then waits for `release()` (or cancellation).
final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    enum FakeError: Error { case failed }

    private let lock = NSLock()
    private var downloaded: Set<String>
    private let steps: [Double]
    private let fails: Bool
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    private var _downloadCalls = 0

    init(downloaded: Set<String> = [], steps: [Double] = [0.5], fails: Bool = false) {
        self.downloaded = downloaded
        self.steps = steps
        self.fails = fails
        (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    }

    var downloadCalls: Int { lock.withLock { _downloadCalls } }

    func release() { gateContinuation.yield() }

    func download(
        _ model: MLXModelInfo, to _: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        lock.withLock { _downloadCalls += 1 }
        for step in steps { progress(step) }
        for await _ in gate { break }
        try Task.checkCancellation()
        if fails { throw FakeError.failed }
        _ = lock.withLock { downloaded.insert(model.id) }
    }

    func isDownloaded(_ model: MLXModelInfo, at _: URL) -> Bool {
        lock.withLock { downloaded.contains(model.id) }
    }

    func delete(_ model: MLXModelInfo, at _: URL) throws {
        _ = lock.withLock { downloaded.remove(model.id) }
    }
}

@MainActor
struct MLXModelStoreTests {
    private let model = MLXModelRegistry.default
    private let plenty: Int64 = 10_000_000_000

    private func makeDefaults() -> UserDefaults {
        let name = "MLXModelStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeStore(_ downloader: FakeDownloader, defaults: UserDefaults? = nil) -> MLXModelStore {
        MLXModelStore(
            downloader: downloader,
            baseDirectory: FileManager.default.temporaryDirectory.appending(path: "MLXModelStoreTests"),
            defaults: defaults ?? makeDefaults())
    }

    @Test func registryDefaultIsQwen25() {
        #expect(MLXModelRegistry.default.id == "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        #expect(MLXModelRegistry.default.revision == "main")
        #expect(MLXModelRegistry.all.map(\.id).contains("mlx-community/Qwen3-1.7B-4bit"))
        #expect(MLXModelRegistry.qwen3_1_7B.notes.contains("候補のみ"))
    }

    @Test func downloadRefusedWhenDiskTooSmall() {
        let downloader = FakeDownloader()
        let store = makeStore(downloader)

        let result = store.startDownload(model, freeBytes: model.approxBytes, isExpensiveNetwork: false)

        #expect(result == .refusedDiskSpace(requiredBytes: model.approxBytes + model.approxBytes / 2))
        #expect(store.status(of: model) == .notDownloaded)
        #expect(downloader.downloadCalls == 0)
    }

    @Test func expensiveNetworkNeedsConfirmation() async {
        let downloader = FakeDownloader()
        let store = makeStore(downloader)

        let first = store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: true)
        #expect(first == .needsConfirmation)
        #expect(store.status(of: model) == .notDownloaded)

        let second = store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: true, confirmed: true)
        #expect(second == .started)
        store.cancelDownload()
        await store.waitForDownload()
    }

    @Test func downloadProgressAndCompletion() async throws {
        let downloader = FakeDownloader()
        let store = makeStore(downloader)

        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .started)
        #expect(try await waitUntil { store.status(of: model) == .downloading(0.5) })
        // Only one download at a time.
        #expect(store.startDownload(MLXModelRegistry.qwen3_1_7B, freeBytes: plenty, isExpensiveNetwork: false) == .busy)

        downloader.release()
        await store.waitForDownload()

        #expect(store.status(of: model) == .downloaded)
        #expect(downloader.downloadCalls == 1)
    }

    @Test func downloadFailureShowsFixedText() async {
        let downloader = FakeDownloader(fails: true)
        let store = makeStore(downloader)

        _ = store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false)
        downloader.release()
        await store.waitForDownload()

        #expect(store.status(of: model) == .failed(MLXModelStore.downloadFailedText))
    }

    @Test func cancelLeavesNotDownloaded() async throws {
        let downloader = FakeDownloader()
        let store = makeStore(downloader)

        _ = store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false)
        #expect(try await waitUntil { store.status(of: model) == .downloading(0.5) })
        store.cancelDownload()
        await store.waitForDownload()
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.status(of: model) == .notDownloaded)
        #expect(!downloader.isDownloaded(model, at: store.baseDirectory))
        // A new download can start afterwards.
        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .started)
        store.cancelDownload()
    }

    @Test func deleteResetsStatus() {
        let downloader = FakeDownloader(downloaded: [model.id])
        let store = makeStore(downloader)
        #expect(store.status(of: model) == .downloaded)

        store.delete(model)

        #expect(store.status(of: model) == .notDownloaded)
        #expect(!downloader.isDownloaded(model, at: store.baseDirectory))
    }

    @Test func selectedModelPersistsAndFallsBack() {
        let defaults = makeDefaults()
        let store = makeStore(FakeDownloader(), defaults: defaults)
        #expect(store.selected == MLXModelRegistry.default)

        store.selected = MLXModelRegistry.qwen3_1_7B
        #expect(defaults.string(forKey: "pocketagent.mlxModel") == MLXModelRegistry.qwen3_1_7B.id)
        #expect(makeStore(FakeDownloader(), defaults: defaults).selected == MLXModelRegistry.qwen3_1_7B)

        defaults.set("someone/unknown-model", forKey: "pocketagent.mlxModel")
        #expect(makeStore(FakeDownloader(), defaults: defaults).selected == MLXModelRegistry.default)
    }

    @Test func hubDownloaderChecksConfigAndWeights() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "HubCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let downloader = HubModelDownloader()
        let directory = base.appending(path: "models").appending(path: model.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data("{}".utf8).write(to: directory.appending(path: "config.json"))
        #expect(!downloader.isDownloaded(model, at: base))
        try Data().write(to: directory.appending(path: "model.safetensors"))
        #expect(downloader.isDownloaded(model, at: base))

        try downloader.delete(model, at: base)
        #expect(!downloader.isDownloaded(model, at: base))
        // Deleting again is not an error.
        try downloader.delete(model, at: base)
    }

    @Test func hubDownloaderThrowsOnSimulator() async {
        #if targetEnvironment(simulator)
        let model = model
        await #expect(throws: MLXUnsupportedOnSimulator.self) {
            try await HubModelDownloader().download(
                model, to: FileManager.default.temporaryDirectory, progress: { _ in })
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
