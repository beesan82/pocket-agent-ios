import Foundation
import PocketAgentCore
import Testing
@testable import PocketAgent

/// Scripted downloader: reports `steps`, then waits for `release()` (or cancellation).
private final class FakePlamoDownloader: PlamoFileDownloading, @unchecked Sendable {
    enum FakeError: Error { case failed }

    private let lock = NSLock()
    private var downloaded: Bool
    private let steps: [Double]
    private let fails: Bool
    private let gate: AsyncStream<Void>
    private let gateContinuation: AsyncStream<Void>.Continuation
    private var _downloadCalls = 0

    init(downloaded: Bool = false, steps: [Double] = [0.5], fails: Bool = false) {
        self.downloaded = downloaded
        self.steps = steps
        self.fails = fails
        (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    }

    var downloadCalls: Int { lock.withLock { _downloadCalls } }

    func release() {
        gateContinuation.yield()
    }

    func download(to _: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { _downloadCalls += 1 }
        for step in steps { progress(step) }
        for await _ in gate { break }
        try Task.checkCancellation()
        if fails { throw FakeError.failed }
        lock.withLock { downloaded = true }
    }

    func isDownloaded(at _: URL) -> Bool {
        lock.withLock { downloaded }
    }

    func delete(at _: URL) throws {
        lock.withLock { downloaded = false }
    }
}

@MainActor
struct PlamoModelStoreTests {
    private let model = PlamoModel.translate08B
    private let plenty: Int64 = 10_000_000_000

    private func makeStore(_ downloader: FakePlamoDownloader) -> PlamoModelStore {
        PlamoModelStore(
            downloader: downloader,
            baseDirectory: FileManager.default.temporaryDirectory.appending(path: "PlamoModelStoreTests"))
    }

    @Test func modelIsPinned() {
        #expect(model.repoID == "pfnet/plamo-3-translate-0.8b-GGUF")
        #expect(model.fileName == "plamo-3-translate-0.8b-Q4_K_M.gguf")
        #expect(model.revision == "1cf96ae02133958a20074bfdfab76517bb737d00")
        #expect(model.fileSizeBytes == 573_126_848)
        #expect(model.license == "PLaMo Community License")
    }

    @Test func downloadRefusedWhenDiskTooSmall() {
        let downloader = FakePlamoDownloader()
        let store = makeStore(downloader)

        let result = store.startDownload(freeBytes: model.fileSizeBytes, isExpensiveNetwork: false)

        #expect(result == .refusedDiskSpace(requiredBytes: model.fileSizeBytes + model.fileSizeBytes / 2))
        #expect(store.status == .notDownloaded)
        #expect(downloader.downloadCalls == 0)
    }

    @Test func expensiveNetworkNeedsConfirmation() async {
        let downloader = FakePlamoDownloader()
        let store = makeStore(downloader)

        let first = store.startDownload(freeBytes: plenty, isExpensiveNetwork: true)
        #expect(first == .needsConfirmation)
        #expect(store.status == .notDownloaded)
        #expect(downloader.downloadCalls == 0)

        let second = store.startDownload(freeBytes: plenty, isExpensiveNetwork: true, confirmed: true)
        #expect(second == .started)
        store.cancelDownload()
        await store.waitForDownload()
    }

    @Test func downloadProgressAndCompletion() async throws {
        let downloader = FakePlamoDownloader()
        let store = makeStore(downloader)

        #expect(store.startDownload(freeBytes: plenty, isExpensiveNetwork: false) == .started)
        #expect(try await waitUntil { store.status == .downloading(0.5) })
        // Only one download at a time.
        #expect(store.startDownload(freeBytes: plenty, isExpensiveNetwork: false) == .busy)

        downloader.release()
        await store.waitForDownload()

        #expect(store.status == .downloaded)
        #expect(downloader.downloadCalls == 1)
    }

    @Test func downloadFailureShowsFixedText() async {
        let downloader = FakePlamoDownloader(fails: true)
        let store = makeStore(downloader)

        _ = store.startDownload(freeBytes: plenty, isExpensiveNetwork: false)
        downloader.release()
        await store.waitForDownload()

        #expect(store.status == .failed(PlamoModelStore.downloadFailedText))
    }

    @Test func cancelLeavesNotDownloaded() async throws {
        let downloader = FakePlamoDownloader()
        let store = makeStore(downloader)

        _ = store.startDownload(freeBytes: plenty, isExpensiveNetwork: false)
        #expect(try await waitUntil { store.status == .downloading(0.5) })
        store.cancelDownload()
        await store.waitForDownload()

        #expect(store.status == .notDownloaded)
        #expect(!downloader.isDownloaded(at: store.directory))
        // A new download can start afterwards.
        #expect(store.startDownload(freeBytes: plenty, isExpensiveNetwork: false) == .started)
        store.cancelDownload()
        await store.waitForDownload()
    }

    @Test func deleteResetsStatus() {
        let downloader = FakePlamoDownloader(downloaded: true)
        let store = makeStore(downloader)
        #expect(store.status == .downloaded)

        store.delete()

        #expect(store.status == .notDownloaded)
        #expect(!downloader.isDownloaded(at: store.directory))
    }

    @Test func downloaderDirectoryLayout() {
        let directory = HubPlamoDownloader.directory(of: model, at: URL(fileURLWithPath: "/b", isDirectory: true))
        #expect(directory.path(percentEncoded: false) == "/b/models/pfnet/plamo-3-translate-0.8b-GGUF/")
    }

    @Test func hubDownloaderChecksFileSize() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "PlamoFiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let downloader = HubPlamoDownloader()
        let directory = HubPlamoDownloader.directory(of: model, at: base)
        #expect(!downloader.isDownloaded(at: directory))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: model.fileName)
        // Exactly the published size, without writing 573 MB: seek and write the last byte.
        #expect(FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(model.fileSizeBytes - 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(downloader.isDownloaded(at: directory))

        // One byte short (a truncated download) is not complete.
        let short = try FileHandle(forWritingTo: file)
        try short.truncate(atOffset: UInt64(model.fileSizeBytes - 1))
        try short.close()
        #expect(!downloader.isDownloaded(at: directory))

        try downloader.delete(at: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        // Deleting again is not an error.
        try downloader.delete(at: directory)
    }

    @Test func hubDownloaderThrowsOnSimulator() async {
        #if targetEnvironment(simulator)
        let directory = FileManager.default.temporaryDirectory.appending(path: "PlamoSim-\(UUID().uuidString)")
        await #expect(throws: MLXUnsupportedOnSimulator.self) {
            try await HubPlamoDownloader().download(to: directory, progress: { _ in })
        }
        #endif
    }

    // MARK: - Download preparation (ADR-052)

    /// Creates a sparse file of exactly `size` bytes (seek + write the last byte).
    private func writeSparseFile(at url: URL, size: Int64) throws {
        #expect(FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
    }

    private func makePlamoDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "PlamoPrepare-\(UUID().uuidString)")
        let directory = HubPlamoDownloader.directory(of: model, at: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func prepareForDownloadKeepsCompleteTargetAndRemovesStrayGGUFs() throws {
        let downloader = HubPlamoDownloader()
        let directory = try makePlamoDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: model.fileName)
        try writeSparseFile(at: target, size: model.fileSizeBytes)
        // Leftovers of the snapshot bug (ADR-052): other quantizations of the same repo.
        let stray1 = directory.appending(path: "plamo-3-translate-0.8b-Q2_K.gguf")
        let stray2 = directory.appending(path: "plamo-3-translate-0.8b-Q8_0.gguf")
        try writeSparseFile(at: stray1, size: 128)
        try writeSparseFile(at: stray2, size: 128)
        let note = directory.appending(path: "note.txt")
        try Data().write(to: note)

        #expect(downloader.prepareForDownload(in: directory))

        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: stray1.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: stray2.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: note.path(percentEncoded: false)))
    }

    @Test func prepareForDownloadRemovesIncompleteTarget() throws {
        let downloader = HubPlamoDownloader()
        let directory = try makePlamoDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: model.fileName)
        try writeSparseFile(at: target, size: model.fileSizeBytes - 1)

        #expect(!downloader.prepareForDownload(in: directory))
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }

    @Test func prepareForDownloadWithoutTargetIsNotComplete() throws {
        let downloader = HubPlamoDownloader()
        let directory = try makePlamoDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!downloader.prepareForDownload(in: directory))
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
