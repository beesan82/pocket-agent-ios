import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

/// One-shot gate that ignores task cancellation (imitates a Hub/MLX call that keeps running).
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }
}

/// Scripted downloader: reports `steps`, then waits for `release()` (or cancellation).
final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    enum FakeError: Error { case failed }

    private let lock = NSLock()
    private var downloaded: Set<String>
    private let steps: [Double]
    private let fails: Bool
    private let ignoresCancellation: Bool
    private let hold = TestGate()
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    private var _downloadCalls = 0

    init(
        downloaded: Set<String> = [], steps: [Double] = [0.5], fails: Bool = false, ignoresCancellation: Bool = false
    ) {
        self.downloaded = downloaded
        self.steps = steps
        self.fails = fails
        self.ignoresCancellation = ignoresCancellation
        (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    }

    var downloadCalls: Int { lock.withLock { _downloadCalls } }

    func release() {
        gateContinuation.yield()
        hold.open()
    }

    func download(
        _ model: MLXModelInfo, to _: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        lock.withLock { _downloadCalls += 1 }
        for step in steps { progress(step) }
        if ignoresCancellation {
            await hold.wait()
        } else {
            for await _ in gate { break }
        }
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

/// Real local writes continue after cancellation, as a snapshot writer can do.
private final class DelayedFileDownloader: ModelDownloading, @unchecked Sendable {
    let started = TestGate()
    let release = TestGate()
    private let hub = HubModelDownloader()

    func download(
        _ model: MLXModelInfo, to base: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let directory = HubModelDownloader.directory(of: model, at: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("in progress".utf8).write(to: directory.appending(path: "writer.tmp"))
        started.open()
        await release.wait()
        // Intentionally ignores cancellation, and can recreate a prematurely deleted directory.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("late write".utf8).write(to: directory.appending(path: "writer.tmp"))
    }

    func isDownloaded(_ model: MLXModelInfo, at base: URL) -> Bool {
        hub.isDownloaded(model, at: base)
    }

    func delete(_ model: MLXModelInfo, at base: URL) throws {
        try hub.delete(model, at: base)
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

    @Test func registryOffersQwen3_4BInstruct() {
        let model = MLXModelRegistry.qwen3_4B
        #expect(model.id == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        #expect(model.revision == "main")
        // Hugging Face siblings total (checked 2026-10-28); DiskSpaceRule needs 1.5x of this.
        #expect(model.approxBytes == 2_278_972_236)
        #expect(model.license == "Apache-2.0")
        #expect(MLXModelRegistry.all.last == model)
        #expect(MLXModelRegistry.model(id: model.id) == model)
        #expect(MLXModelRegistry.default == MLXModelRegistry.qwen25_1_5B)
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

        #expect(store.status(of: model) == .notDownloaded)
        #expect(!downloader.isDownloaded(model, at: store.baseDirectory))
        // A new download can start afterwards.
        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .started)
        store.cancelDownload()
    }

    @Test func cancelStaysBusyUntilTaskEnds() async throws {
        let downloader = FakeDownloader(ignoresCancellation: true)
        let store = makeStore(downloader)

        _ = store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false)
        #expect(try await waitUntil { store.status(of: model) == .downloading(0.5) })
        store.cancelDownload()

        #expect(store.status(of: model) == .notDownloaded)
        // The cancelled task may still write files: no new download until it ends.
        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .busy)

        downloader.release()
        await store.waitForDownload()
        #expect(store.status(of: model) == .notDownloaded)
        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .started)
        store.cancelDownload()
        await store.waitForDownload()
    }

    @Test func progressNeverGoesBackwards() async throws {
        let downloader = FakeDownloader(steps: [0.6, 0.3])
        let store = makeStore(downloader)

        _ = store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false)
        #expect(try await waitUntil { store.status(of: model) != .downloading(0) })
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.status(of: model) == .downloading(0.6))
        store.cancelDownload()
        await store.waitForDownload()
    }

    @Test func deleteResetsStatus() {
        let downloader = FakeDownloader(downloaded: [model.id])
        let store = makeStore(downloader)
        #expect(store.status(of: model) == .downloaded)

        store.delete(model)

        #expect(store.status(of: model) == .notDownloaded)
        #expect(!downloader.isDownloaded(model, at: store.baseDirectory))
    }

    @Test(arguments: [false, true])
    func deleteWaitsForWriterAndRemovesLateWrites(cancelFirst: Bool) async {
        let base = FileManager.default.temporaryDirectory.appending(path: "HubRace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let downloader = DelayedFileDownloader()
        let store = MLXModelStore(downloader: downloader, baseDirectory: base, defaults: makeDefaults())
        let directory = HubModelDownloader.directory(of: model, at: base)

        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .started)
        await downloader.started.wait()
        if cancelFirst { store.cancelDownload() }
        store.delete(model)

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "writer.tmp").path))
        #expect(store.startDownload(model, freeBytes: plenty, isExpensiveNetwork: false) == .busy)
        downloader.release.open()
        await store.waitForDownload()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.status(of: model) == .notDownloaded)
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

    /// Models downloaded by earlier builds (swift-transformers `HubApi`) must load without re-downloading.
    @Test func downloaderDirectoryLayoutUnchanged() {
        let directory = HubModelDownloader.directory(
            of: MLXModelRegistry.default, at: URL(fileURLWithPath: "/b", isDirectory: true))
        #expect(directory.path(percentEncoded: false) == "/b/models/\(MLXModelRegistry.default.id)/")
        #expect(MLXModelRegistry.default.id == "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
    }

    @Test func hubDownloaderChecksConfigTokenizerAndWeights() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "HubCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let downloader = HubModelDownloader()
        let directory = base.appending(path: "models").appending(path: model.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data("{}".utf8).write(to: directory.appending(path: "config.json"))
        #expect(!downloader.isDownloaded(model, at: base))
        try Data().write(to: directory.appending(path: "model.safetensors"))
        #expect(!downloader.isDownloaded(model, at: base))
        try tinyWeights().write(to: directory.appending(path: "model.safetensors"))
        #expect(!downloader.isDownloaded(model, at: base))
        try Data(validTokenizer.utf8).write(to: directory.appending(path: "tokenizer.json"))
        try Data(validTokenizerConfig.utf8).write(to: directory.appending(path: "tokenizer_config.json"))
        #expect(downloader.isDownloaded(model, at: base))

        try downloader.delete(model, at: base)
        #expect(!downloader.isDownloaded(model, at: base))
        // Deleting again is not an error.
        try downloader.delete(model, at: base)
    }

    @Test(arguments: ["", "{", "[]", "null"])
    func hubDownloaderRejectsInvalidConfig(json: String) throws {
        try withValidModel { base, directory in
            try Data(json.utf8).write(to: directory.appending(path: "config.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test(arguments: [
        "", "{", "[]", "{}", #"{"model":{}}"#,
        #"{"model":{"type":"BPE","vocab":{},"merges":[]}}"#,
        #"{"model":{"type":"BPE","vocab":{"a":0}}}"#,
        #"{"model":{"type":"BPE","vocab":{"a":"invalid"},"merges":[]}}"#
    ])
    func hubDownloaderRejectsInvalidTokenizer(json: String) throws {
        try withValidModel { base, directory in
            try Data(json.utf8).write(to: directory.appending(path: "tokenizer.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test func hubDownloaderRequiresTokenizerConfiguration() throws {
        try withValidModel { base, directory in
            try FileManager.default.removeItem(at: directory.appending(path: "tokenizer_config.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test(arguments: ["", "{", "[]", "null"])
    func hubDownloaderRejectsInvalidTokenizerConfiguration(json: String) throws {
        try withValidModel { base, directory in
            try Data(json.utf8).write(to: directory.appending(path: "tokenizer_config.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test func hubDownloaderRejectsTruncatedWeights() throws {
        try withValidModel { base, directory in
            let weights = tinyWeights()
            // Empty, partial length prefix, partial JSON header, and missing final tensor byte.
            for count in [0, 4, 12, weights.count - 1] {
                try Data(weights.prefix(count)).write(to: directory.appending(path: "model.safetensors"))
                #expect(!HubModelDownloader().isDownloaded(model, at: base))
            }
        }
    }

    @Test(arguments: [
        "{}",
        "not json",
        #"{"weight":{"dtype":"U8","shape":[18446744073709551615,2],"data_offsets":[0,4]}}"#,
        #"{"weight":{"dtype":"U8","shape":[4],"data_offsets":[0,5]}}"#,
        #"{"weight":{"dtype":"U8","shape":[4],"data_offsets":[3,2]}}"#,
        #"{"weight":{"dtype":"F32","shape":[4],"data_offsets":[0,4]}}"#
    ])
    func hubDownloaderRejectsInvalidWeightHeaders(header: String) throws {
        try withValidModel { base, directory in
            try tinyWeights(header: header).write(to: directory.appending(path: "model.safetensors"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test func hubDownloaderRejectsUnboundedHeaderLength() throws {
        try withValidModel { base, directory in
            try Data(repeating: 0xff, count: 8).write(to: directory.appending(path: "model.safetensors"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test func hubDownloaderRejectsIndexPointingToWrongTensor() throws {
        try withValidModel { base, directory in
            let index = #"{"weight_map":{"missing_tensor":"model.safetensors"}}"#
            try Data(index.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test func hubDownloaderRequiresEveryIndexedShard() throws {
        try withValidModel { base, directory in
            try FileManager.default.removeItem(at: directory.appending(path: "model.safetensors"))
            let index = #"{"weight_map":{"weight":"model-00001-of-00002.safetensors","other":"model-00002-of-00002.safetensors"}}"#
            try Data(index.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))
            try tinyWeights().write(to: directory.appending(path: "model-00001-of-00002.safetensors"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
            let second = directory.appending(path: "model-00002-of-00002.safetensors")
            try Data().write(to: second)
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
            try tinyWeights(header: #"{"other":{"dtype":"U8","shape":[4],"data_offsets":[0,4]}}"#).write(to: second)
            #expect(HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test func numberedShardsNeedCompleteSetAndIndex() throws {
        try withValidModel { base, directory in
            try FileManager.default.removeItem(at: directory.appending(path: "model.safetensors"))
            try tinyWeights().write(to: directory.appending(path: "model-00001-of-00002.safetensors"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
            let index = #"{"weight_map":{"weight":"model-00001-of-00002.safetensors"}}"#
            try Data(index.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
            try tinyWeights(header: #"{"other":{"dtype":"U8","shape":[4],"data_offsets":[0,4]}}"#)
                .write(to: directory.appending(path: "model-00002-of-00002.safetensors"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
            let complete = #"{"weight_map":{"weight":"model-00001-of-00002.safetensors","other":"model-00002-of-00002.safetensors"}}"#
            try Data(complete.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))
            #expect(HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    @Test(arguments: ["{", "{}", #"{"weight_map":{}}"#, #"{"weight_map":{"weight":"../outside.safetensors"}}"#])
    func hubDownloaderRejectsInvalidWeightIndex(json: String) throws {
        try withValidModel { base, directory in
            try Data(json.utf8).write(to: directory.appending(path: "model.safetensors.index.json"))
            #expect(!HubModelDownloader().isDownloaded(model, at: base))
        }
    }

    private var validTokenizer: String {
        #"{"version":"1.0","model":{"type":"BPE","vocab":{"a":0},"merges":[]}}"#
    }

    private var validTokenizerConfig: String {
        #"{"tokenizer_class":"Qwen2Tokenizer","eos_token":"a"}"#
    }

    /// Four real U8 tensor bytes, with a little-endian length and an 8-byte-padded JSON header.
    private func tinyWeights(
        header: String = #"{"weight":{"dtype":"U8","shape":[4],"data_offsets":[0,4]}}"#
    ) -> Data {
        var json = Data(header.utf8)
        while json.count % 8 != 0 { json.append(0x20) }
        var length = UInt64(json.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(json)
        data.append(contentsOf: [1, 2, 3, 4])
        return data
    }

    private func withValidModel(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "HubFiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = HubModelDownloader.directory(of: model, at: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appending(path: "config.json"))
        try Data(validTokenizer.utf8).write(to: directory.appending(path: "tokenizer.json"))
        try Data(validTokenizerConfig.utf8).write(to: directory.appending(path: "tokenizer_config.json"))
        try tinyWeights().write(to: directory.appending(path: "model.safetensors"))
        try body(base, directory)
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
