import AgentRunKit
import Foundation
import FoundationModels
import MLXFoundationModels
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers
import UIKit

/// A loaded on-device model: text generation for the journal, and the Foundation Models model
/// for chat (nil in test doubles). `release` frees it; it is called once, when the model is dropped.
struct LoadedOnDeviceModel: Sendable {
    let textClient: any LLMClient
    let languageModel: (any OnDeviceLanguageModel)?
    let release: @Sendable () -> Void
}

protocol ModelLoading: Sendable {
    /// Loads from the local model directory only (never downloads).
    func load(_ model: MLXModelInfo, directory: URL) async throws -> LoadedOnDeviceModel
}

/// Thrown when the model directory has no `config.json` (never downloads to recover).
struct MLXModelFilesMissing: Error {}

/// Real loader: `MLXLanguageModel` (mlx-swift-lm 3.32.3 MLXFoundationModels) over the local
/// directory. On the simulator it never touches MLX.
struct MLXModelLoader: ModelLoading {
    func load(_ model: MLXModelInfo, directory: URL) async throws -> LoadedOnDeviceModel {
        #if targetEnvironment(simulator)
        throw MLXUnsupportedOnSimulator()
        #else
        guard FileManager.default.fileExists(
            atPath: directory.appending(path: "config.json").path(percentEncoded: false))
        else { throw MLXModelFilesMissing() }
        // Weights and tokenizer come from the downloaded directory only: no Hub request (ADR-023).
        let languageModel = MLXLanguageModel(
            configuration: ModelConfiguration(directory: directory),
            capabilities: [.toolCalling],
            weightsLocation: { _ in directory },
            load: { _, _ in
                try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
            })
        try await languageModel.preload()
        return LoadedOnDeviceModel(
            textClient: FoundationModelsTextClient(model: languageModel),
            languageModel: languageModel,
            release: { Task { await languageModel.evict() } })
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
    /// The loaded model for on-device chat (Foundation Models session with tools).
    private(set) var languageModel: (any OnDeviceLanguageModel)?
    private(set) var loadedModelID: String?
    private(set) var lastLoadSeconds: Double?

    @ObservationIgnored private let store: MLXModelStore
    @ObservationIgnored private let loader: any ModelLoading
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Result<LoadedOnDeviceModel, any Error>, Never>?
    @ObservationIgnored private var releaseLoaded: (@Sendable () -> Void)?
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
        let task = Task<Result<LoadedOnDeviceModel, any Error>, Never> {
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
            if case let .success(late) = result { late.release() }
            return
        }
        loadTask = nil
        loadingModelID = nil
        switch result {
        case let .success(loaded):
            client = loaded.textClient
            languageModel = loaded.languageModel
            releaseLoaded = loaded.release
            loadedModelID = model.id
            lastLoadSeconds = Self.seconds(ContinuousClock.now - start)
            state = .loaded
        case .failure:
            state = .failed(Self.loadFailedText)
        }
    }

    /// A deleted model must stop being used: drops it when it is loaded or still loading.
    func modelDeleted(_ model: MLXModelInfo) {
        if loadedModelID == model.id || loadingModelID == model.id { unload() }
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
        let release = releaseLoaded
        client = nil
        languageModel = nil
        releaseLoaded = nil
        loadedModelID = nil
        release?()
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
