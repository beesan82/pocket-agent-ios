import Foundation
import Observation
import PocketAgentCore
import SwiftUI
#if !targetEnvironment(simulator)
import HuggingFace
#endif

/// The PLaMo 3 Translate weights (GGUF), pinned to one revision (ADR-050).
struct PlamoModel: Sendable, Equatable {
    let repoID: String
    let fileName: String
    let revision: String
    let fileSizeBytes: Int64
    let displayName: String
    let license: String

    static let translate08B = PlamoModel(
        repoID: "pfnet/plamo-3-translate-0.8b-GGUF",
        fileName: "plamo-3-translate-0.8b-Q4_K_M.gguf",
        revision: "1cf96ae02133958a20074bfdfab76517bb737d00",
        fileSizeBytes: 573_126_848,
        displayName: "PLaMo 3 Translate 0.8B（GGUF Q4_K_M）",
        license: "PLaMo Community License")
}

/// Downloads one model into its own directory; the store decides where that directory is.
protocol PlamoFileDownloading: Sendable {
    func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func isDownloaded(at directory: URL) -> Bool
    func delete(at directory: URL) throws
}

/// Same layout as the MLX models: `base/models/<repo id>`.
struct HubPlamoDownloader: PlamoFileDownloading {
    let model: PlamoModel

    init(model: PlamoModel = .translate08B) {
        self.model = model
    }

    static func directory(of model: PlamoModel, at base: URL) -> URL {
        base.appending(path: "models", directoryHint: .isDirectory)
            .appending(path: model.repoID, directoryHint: .isDirectory)
    }

    /// Prepares the model directory for a download and reports whether the model
    /// is already there in full. Removes GGUF files other than the pinned one
    /// (the pre-fix snapshot download fetched every quantization in the repo,
    /// about 2.0 GB in total — ADR-052) and a pinned file with the wrong size
    /// (a partial file would block the move into place).
    func prepareForDownload(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasSuffix(".gguf") && name != model.fileName {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
        let target = directory.appending(path: model.fileName)
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path(percentEncoded: false)),
              let size = attributes[.size] as? NSNumber
        else { return false }
        if size.int64Value == model.fileSizeBytes { return true }
        try? fileManager.removeItem(at: target)
        return false
    }

    func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        #if targetEnvironment(simulator)
        throw MLXUnsupportedOnSimulator()
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Models are re-downloadable: keep them out of device backups.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directoryURL = directory
        try? directoryURL.setResourceValues(excluded)

        // The pre-fix snapshot download reported failure after the file had
        // already landed (ADR-052): reuse a complete file instead of refetching.
        if prepareForDownload(in: directory) {
            progress(1)
            return
        }
        guard let repo = Repo.ID(rawValue: model.repoID) else { throw MLXModelIDInvalid() }
        // No cache, and no snapshot: the snapshot API of swift-huggingface 0.13.0
        // throws after a successful download when the client has no cache
        // (ADR-052). Download the one pinned file straight to its final place.
        let hub = HubClient(cache: nil)
        let fileProgress = Progress(totalUnitCount: model.fileSizeBytes)
        // Sampled like the snapshot download did: Progress is thread-safe to read.
        let sampler = Task {
            while !Task.isCancelled {
                progress(fileProgress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampler.cancel() }
        _ = try await hub.downloadFile(
            at: model.fileName, from: repo,
            to: directory.appending(path: model.fileName),
            kind: .model, revision: model.revision, progress: fileProgress)
        progress(1)
        #endif
    }

    /// Complete only when the GGUF file is there with exactly the published size.
    func isDownloaded(at directory: URL) -> Bool {
        let path = directory.appending(path: model.fileName).path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.int64Value == model.fileSizeBytes
    }

    func delete(at directory: URL) throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }
}

/// Download / delete state of the PLaMo model, with the same rules as `MLXModelStore`
/// (user-initiated download only, 1.5x free space, cellular confirmation, one download at a time).
@MainActor
@Observable
final class PlamoModelStore {
    enum Status: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    enum StartResult: Equatable {
        case started
        case refusedDiskSpace(requiredBytes: Int64)
        /// Expensive (cellular) network: the caller confirms, then calls again with `confirmed: true`.
        case needsConfirmation
        /// Only one download at a time.
        case busy
    }

    static let downloadFailedText = "モデルをダウンロードできませんでした。通信状態を確認して、もう一度お試しください。"
    static let deleteFailedText = "モデルを削除できませんでした。"

    let model = PlamoModel.translate08B
    let baseDirectory: URL

    private(set) var status: Status = .notDownloaded

    @ObservationIgnored private let downloader: any PlamoFileDownloading
    /// Kept until the task really ends, even after cancel (Hub may still be writing).
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    /// Remains true while a cancelled download can still write.
    @ObservationIgnored private var isWriting = false
    @ObservationIgnored private var deleteAfterDownload = false
    /// Owner of `status` for the running download; nil once cancelled.
    @ObservationIgnored private var activeToken: UUID?

    init(
        downloader: any PlamoFileDownloading = HubPlamoDownloader(),
        baseDirectory: URL = MLXModelStore.baseDirectory
    ) {
        self.downloader = downloader
        self.baseDirectory = baseDirectory
        refresh()
    }

    var directory: URL {
        HubPlamoDownloader.directory(of: model, at: baseDirectory)
    }

    /// Re-reads the file on disk unless a download (or a cancelled writer) is still running.
    func refresh() {
        guard !isWriting else { return }
        status = diskStatus()
    }

    func startDownload(freeBytes: Int64, isExpensiveNetwork: Bool, confirmed: Bool = false) -> StartResult {
        guard activeTask == nil else { return .busy }
        guard DiskSpaceRule.canDownload(modelBytes: model.fileSizeBytes, freeBytes: freeBytes) else {
            return .refusedDiskSpace(requiredBytes: DiskSpaceRule.requiredBytes(modelBytes: model.fileSizeBytes))
        }
        if isExpensiveNetwork && !confirmed { return .needsConfirmation }

        let token = UUID()
        activeToken = token
        isWriting = true
        status = .downloading(0)
        let downloader = downloader
        let directory = directory
        // The store lives as long as the app; strong captures keep the code simple.
        activeTask = Task {
            let outcome: Result<Void, any Error>
            do {
                try await downloader.download(to: directory) { value in
                    Task { @MainActor in self.applyProgress(value, token: token) }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            self.finishDownload(outcome, token: token)
        }
        return .started
    }

    /// Stops the download. The store stays `.busy` until the cancelled task has ended.
    func cancelDownload() {
        guard activeTask != nil, activeToken != nil else { return }
        activeTask?.cancel()
        activeToken = nil
        // A cancelled writer may still be changing the file. Do not offer it
        // until finishDownload has revalidated the final directory.
        status = .notDownloaded
    }

    func delete() {
        if isWriting {
            deleteAfterDownload = true
            cancelDownload()
            status = .notDownloaded
            // The writer may ignore cancellation. Keep its files until finishDownload runs.
            return
        }
        do {
            try downloader.delete(at: directory)
            status = .notDownloaded
        } catch {
            status = .failed(Self.deleteFailedText)
        }
    }

    var isDeletionPending: Bool {
        isWriting && deleteAfterDownload
    }

    /// Waits until the current (or cancelled) download task has ended.
    func waitForDownload() async {
        await activeTask?.value
    }

    private func applyProgress(_ value: Double, token: UUID) {
        // Callbacks may arrive out of order: never move backwards.
        guard activeToken == token, case let .downloading(current) = status else { return }
        status = .downloading(max(current, min(max(value, 0), 1)))
    }

    private func finishDownload(_ outcome: Result<Void, any Error>, token: UUID) {
        activeTask = nil
        isWriting = false
        if deleteAfterDownload {
            deleteAfterDownload = false
            activeToken = nil
            delete()
            return
        }
        // Cancelled: re-read the disk, the task may have finished the file.
        guard activeToken == token else {
            status = diskStatus()
            return
        }
        activeToken = nil
        switch outcome {
        case .success where downloader.isDownloaded(at: directory):
            status = .downloaded
        case .success, .failure:
            status = .failed(Self.downloadFailedText)
        }
    }

    private func diskStatus() -> Status {
        downloader.isDownloaded(at: directory) ? .downloaded : .notDownloaded
    }
}

/// Status line of the PLaMo model, worded like `ModelStatusView`.
struct PlamoModelStatusView: View {
    let status: PlamoModelStore.Status

    var body: some View {
        switch status {
        case .notDownloaded:
            Text("未ダウンロード").font(.subheadline)
        case let .downloading(fraction):
            ProgressView(value: fraction) {
                Text("ダウンロード中 \(Int(fraction * 100))%").font(.subheadline)
            }
        case .downloaded:
            Text("ダウンロード済み").font(.subheadline)
        case let .failed(text):
            Text(text).font(.subheadline).foregroundStyle(.red)
        }
    }
}
