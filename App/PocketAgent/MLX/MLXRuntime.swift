import AgentRunKit
import Foundation
import Observation
import UIKit
#if !targetEnvironment(simulator)
import AgentRunKitMLX
import Hub
import MLX
import MLXLMCommon
#endif

protocol ModelLoading: Sendable {
    /// Loads from the local model directory only (never downloads).
    func load(_ model: MLXModelInfo, directory: URL) async throws -> any LLMClient
    /// Frees cached GPU buffers after the client has been dropped.
    func releaseMemory()
}

/// Thrown when the model directory has no `config.json` (never downloads to recover).
struct MLXModelFilesMissing: Error {}

/// Real loader. On the simulator it never touches MLX or Hub.
struct MLXModelLoader: ModelLoading {
    func load(_ model: MLXModelInfo, directory: URL) async throws -> any LLMClient {
        #if targetEnvironment(simulator)
        throw MLXUnsupportedOnSimulator()
        #else
        guard FileManager.default.fileExists(
            atPath: directory.appending(path: "config.json").path(percentEncoded: false))
        else { throw MLXModelFilesMissing() }
        Memory.cacheLimit = 64 * 1024 * 1024
        // A directory configuration skips `hub.snapshot` (mlx-swift-lm 2.30.6 `downloadModel` returns the
        // directory as-is; the tokenizer is read with `LanguageModelConfigurationFromHub(modelFolder:)`).
        let container = try await loadModelContainer(
            hub: HubApi(useOfflineMode: true),
            configuration: ModelConfiguration(directory: directory),
            progressHandler: { _ in })
        return MLXClient(
            container: container, model: model.id,
            parameters: GenerateParameters(temperature: 0.7, topP: 0.8, repetitionPenalty: 1.1))
        #endif
    }

    func releaseMemory() {
        #if !targetEnvironment(simulator)
        Memory.clearCache()
        #endif
    }
}

/// Holds at most one loaded MLX client. Screens call `load` before use.
@MainActor
@Observable
final class MLXRuntime {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case unloadedForMemory
        case failed(String)
    }

    static let loadFailedText = "モデルを読み込めませんでした。端末を再起動するか、モデルを削除して再ダウンロードしてください。"

    private(set) var state: State = .idle
    private(set) var client: (any LLMClient)?
    private(set) var loadedModelID: String?
    private(set) var lastLoadSeconds: Double?

    @ObservationIgnored private let store: MLXModelStore
    @ObservationIgnored private let loader: any ModelLoading
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Result<any LLMClient, any Error>, Never>?
    @ObservationIgnored private var loadingModelID: String?
    @ObservationIgnored private var memoryObserver: ObserverToken?

    init(
        store: MLXModelStore,
        loader: any ModelLoading = MLXModelLoader(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.loader = loader
        let token = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // UIKit posts this on the main thread; hop if someone posts elsewhere.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handleMemoryWarning() }
            } else {
                Task { @MainActor in self?.handleMemoryWarning() }
            }
        }
        memoryObserver = ObserverToken(center: notificationCenter, token: token)
    }

    /// Loads `model` from its local directory. At most one load runs at a time:
    /// a second call for the same model waits for the running one; another model cancels it.
    func load(_ model: MLXModelInfo) async {
        if state == .loaded, loadedModelID == model.id { return }
        if let running = loadTask, loadingModelID == model.id {
            _ = await running.value
            return
        }
        cancelLoad()
        dropClient()
        generation += 1
        let current = generation
        state = .loading
        loadingModelID = model.id
        let loader = loader
        let directory = HubModelDownloader.directory(of: model, at: store.baseDirectory)
        let start = ContinuousClock.now
        let task = Task<Result<any LLMClient, any Error>, Never> {
            do {
                return .success(try await loader.load(model, directory: directory))
            } catch {
                return .failure(error)
            }
        }
        loadTask = task
        let result = await task.value

        guard current == generation else {
            // Cancelled or superseded: a container that loaded anyway is dropped here.
            if case .success = result { loader.releaseMemory() }
            return
        }
        loadTask = nil
        loadingModelID = nil
        switch result {
        case let .success(loaded):
            client = loaded
            loadedModelID = model.id
            lastLoadSeconds = Self.seconds(ContinuousClock.now - start)
            state = .loaded
        case .failure:
            state = .failed(Self.loadFailedText)
        }
    }

    func unload() {
        cancelLoad()
        dropClient()
        state = .idle
    }

    func handleMemoryWarning() {
        guard state == .loaded || state == .loading else { return }
        unload()
        state = .unloadedForMemory
    }

    /// Invalidates the running load; its result is discarded when it ends.
    private func cancelLoad() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        loadingModelID = nil
    }

    private func dropClient() {
        let hadClient = client != nil
        client = nil
        loadedModelID = nil
        if hadClient { loader.releaseMemory() }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Removes a block-based observer when the owner goes away.
private final class ObserverToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, token: any NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}
