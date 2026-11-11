import Foundation
import Observation
import PocketAgentCore
#if !targetEnvironment(simulator)
import HuggingFace
#endif

/// Thrown by the real MLX/Hub implementations on the simulator, where MLX cannot run.
struct MLXUnsupportedOnSimulator: Error {}

/// The model id is not a Hugging Face repo id ("owner/name"), so nothing can be downloaded.
struct MLXModelIDInvalid: Error {}

protocol ModelDownloading: Sendable {
    func download(
        _ model: MLXModelInfo, to base: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws
    func isDownloaded(_ model: MLXModelInfo, at base: URL) -> Bool
    func delete(_ model: MLXModelInfo, at base: URL) throws
}

/// Files live where swift-transformers' `HubApi` put them in earlier builds: `base/models/<repo id>`,
/// so models downloaded before the move to swift-huggingface keep loading without a new download.
struct HubModelDownloader: ModelDownloading {
    static let globs = ["*.safetensors", "*.json", "*.txt", "*.model", "*.tiktoken"]

    static func directory(of model: MLXModelInfo, at base: URL) -> URL {
        base.appending(path: "models", directoryHint: .isDirectory)
            .appending(path: model.id, directoryHint: .isDirectory)
    }

    /// One file of a repo listing, as needed for selection and progress weights.
    struct SnapshotFile: Equatable, Sendable {
        let path: String
        let size: Int64
    }

    /// The files the snapshot download would have fetched: glob-filtered with
    /// the same fnmatch semantics (flags 0, so "*" also crosses directories).
    static func selectFiles(_ entries: [SnapshotFile]) -> [SnapshotFile] {
        entries.filter { entry in
            globs.contains { fnmatch($0, entry.path, 0) == 0 }
        }
    }

    func download(
        _ model: MLXModelInfo, to base: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        #if targetEnvironment(simulator)
        throw MLXUnsupportedOnSimulator()
        #else
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Models are re-downloadable: keep them out of device backups.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var baseURL = base
        try? baseURL.setResourceValues(excluded)

        guard let repo = Repo.ID(rawValue: model.id) else { throw MLXModelIDInvalid() }
        // No cache, and no snapshot: the snapshot API of swift-huggingface 0.13.0
        // throws after a successful download when the client has no cache
        // (ADR-052). Fetch the same file set file by file instead.
        let hub = HubClient(cache: nil)
        let directory = Self.directory(of: model, at: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = try await hub.listFiles(in: repo, kind: .model, revision: model.revision, recursive: true)
        let files = Self.selectFiles(entries.filter { $0.type == .file }.map {
            SnapshotFile(path: $0.path, size: Int64($0.effectiveSize ?? 0))
        })
        let totalWeight = files.reduce(Int64(0)) { $0 + max($1.size, 1) }
        let aggregate = Progress(totalUnitCount: max(totalWeight, 1))
        // Sampled like the snapshot download did: Progress is thread-safe to read.
        let sampler = Task {
            while !Task.isCancelled {
                progress(aggregate.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { sampler.cancel() }
        for file in files {
            let destination = directory.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let child = Progress(
                totalUnitCount: max(file.size, 1), parent: aggregate, pendingUnitCount: max(file.size, 1))
            _ = try await hub.downloadFile(
                at: file.path, from: repo, to: destination,
                kind: .model, revision: model.revision, progress: child)
        }
        progress(1)
        #endif
    }

    func isDownloaded(_ model: MLXModelInfo, at base: URL) -> Bool {
        ModelFileValidator.isComplete(at: Self.directory(of: model, at: base))
    }

    func delete(_ model: MLXModelInfo, at base: URL) throws {
        do {
            try FileManager.default.removeItem(at: Self.directory(of: model, at: base))
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }
}

/// Download / delete state of the MLX models (FR: user-initiated download only).
@MainActor
@Observable
final class MLXModelStore {
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

    static let selectedModelKey = "pocketagent.mlxModel"
    static let downloadFailedText = "モデルをダウンロードできませんでした。通信状態を確認して、もう一度お試しください。"
    static let deleteFailedText = "モデルを削除できませんでした。"

    /// Pure derivation from `URL.applicationSupportDirectory`; touches no actor state, so
    /// nonisolated code (LlamaCppPlamoEngine.defaultModelURL, ADR-051) may read it directly.
    nonisolated static var baseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    let baseDirectory: URL

    var selected: MLXModelInfo {
        didSet { defaults.set(selected.id, forKey: Self.selectedModelKey) }
    }

    private var statuses: [String: Status] = [:]
    @ObservationIgnored private let downloader: any ModelDownloading
    @ObservationIgnored private let defaults: UserDefaults
    /// Kept until the task really ends, even after cancel (Hub may still be writing).
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    /// Model whose status the running download owns; nil once cancelled.
    @ObservationIgnored private var activeModelID: String?
    /// Unlike activeModelID, remains set while a cancelled download can still write.
    @ObservationIgnored private var writingModelID: String?
    @ObservationIgnored private var deleteAfterDownload = false
    @ObservationIgnored private var activeToken: UUID?

    init(
        downloader: any ModelDownloading = HubModelDownloader(),
        baseDirectory: URL = MLXModelStore.baseDirectory,
        defaults: UserDefaults = .standard
    ) {
        self.downloader = downloader
        self.baseDirectory = baseDirectory
        self.defaults = defaults
        selected = defaults.string(forKey: Self.selectedModelKey).flatMap(MLXModelRegistry.model(id:))
            ?? MLXModelRegistry.default
        refresh()
    }

    func status(of model: MLXModelInfo) -> Status {
        statuses[model.id] ?? .notDownloaded
    }

    /// Re-reads the files on disk for every model that is not downloading.
    func refresh() {
        for model in MLXModelRegistry.all where model.id != writingModelID {
            statuses[model.id] = downloader.isDownloaded(model, at: baseDirectory) ? .downloaded : .notDownloaded
        }
    }

    func startDownload(
        _ model: MLXModelInfo, freeBytes: Int64, isExpensiveNetwork: Bool, confirmed: Bool = false
    ) -> StartResult {
        guard activeTask == nil else { return .busy }
        guard DiskSpaceRule.canDownload(modelBytes: model.approxBytes, freeBytes: freeBytes) else {
            return .refusedDiskSpace(requiredBytes: DiskSpaceRule.requiredBytes(modelBytes: model.approxBytes))
        }
        if isExpensiveNetwork && !confirmed { return .needsConfirmation }

        let token = UUID()
        activeToken = token
        activeModelID = model.id
        writingModelID = model.id
        statuses[model.id] = .downloading(0)
        let downloader = downloader
        let base = baseDirectory
        // The store lives as long as the app; strong captures keep the code simple.
        activeTask = Task {
            let outcome: Result<Void, any Error>
            do {
                try await downloader.download(model, to: base) { value in
                    Task { @MainActor in self.applyProgress(value, token: token, modelID: model.id) }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            self.finishDownload(outcome, token: token, model: model)
        }
        return .started
    }

    /// Stops the download. The store stays `.busy` until the cancelled task has ended.
    func cancelDownload() {
        guard activeTask != nil, let modelID = activeModelID else { return }
        activeTask?.cancel()
        activeModelID = nil
        activeToken = nil
        // A cancelled writer may still be changing the files. Do not offer them
        // for inference until finishDownload has revalidated the final directory.
        statuses[modelID] = .notDownloaded
    }

    func delete(_ model: MLXModelInfo) {
        if writingModelID == model.id {
            deleteAfterDownload = true
            cancelDownload()
            statuses[model.id] = .notDownloaded
            // The writer may ignore cancellation. Keep its files until finishDownload runs.
            return
        }
        do {
            try downloader.delete(model, at: baseDirectory)
            statuses[model.id] = .notDownloaded
        } catch {
            statuses[model.id] = .failed(Self.deleteFailedText)
        }
    }

    func isDeletionPending(_ model: MLXModelInfo) -> Bool {
        writingModelID == model.id && deleteAfterDownload
    }

    /// Waits until the current (or cancelled) download task has ended.
    func waitForDownload() async {
        await activeTask?.value
    }

    private func applyProgress(_ value: Double, token: UUID, modelID: String) {
        // Callbacks may arrive out of order: never move backwards.
        guard activeToken == token, case let .downloading(current) = statuses[modelID] else { return }
        statuses[modelID] = .downloading(max(current, min(max(value, 0), 1)))
    }

    private func finishDownload(_ outcome: Result<Void, any Error>, token: UUID, model: MLXModelInfo) {
        activeTask = nil
        writingModelID = nil
        if deleteAfterDownload {
            deleteAfterDownload = false
            activeModelID = nil
            activeToken = nil
            delete(model)
            return
        }
        // Cancelled: re-read the disk, the task may have finished some files.
        guard activeToken == token else {
            statuses[model.id] = diskStatus(of: model.id)
            return
        }
        activeModelID = nil
        activeToken = nil
        switch outcome {
        case .success where downloader.isDownloaded(model, at: baseDirectory):
            statuses[model.id] = .downloaded
        case .success, .failure:
            statuses[model.id] = .failed(Self.downloadFailedText)
        }
    }

    private func diskStatus(of modelID: String) -> Status {
        guard let model = MLXModelRegistry.model(id: modelID) else { return .notDownloaded }
        return downloader.isDownloaded(model, at: baseDirectory) ? .downloaded : .notDownloaded
    }
}
