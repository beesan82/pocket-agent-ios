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
        // No cache: files go straight into the model directory (a cache would keep a second copy).
        let hub = HubClient(cache: nil)
        _ = try await hub.downloadSnapshot(
            of: repo, kind: .model, to: Self.directory(of: model, at: base), revision: model.revision,
            matching: Self.globs,
            progressHandler: { (value: Progress) in progress(value.fractionCompleted) })
        #endif
    }

    func isDownloaded(_ model: MLXModelInfo, at base: URL) -> Bool {
        let directory = Self.directory(of: model, at: base)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appending(path: "config.json").path(percentEncoded: false))
        else { return false }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.contains { $0.hasSuffix(".safetensors") }
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

    static var baseDirectory: URL {
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
        for model in MLXModelRegistry.all where model.id != activeModelID {
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
        statuses[modelID] = diskStatus(of: modelID)
    }

    func delete(_ model: MLXModelInfo) {
        if activeModelID == model.id { cancelDownload() }
        do {
            try downloader.delete(model, at: baseDirectory)
            statuses[model.id] = .notDownloaded
        } catch {
            statuses[model.id] = .failed(Self.deleteFailedText)
        }
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
