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
    func load(_ model: MLXModelInfo, from base: URL) async throws -> any LLMClient
    /// Frees cached GPU buffers after the client has been dropped.
    func releaseMemory()
}

/// Real loader. On the simulator it never touches MLX or Hub.
struct MLXModelLoader: ModelLoading {
    func load(_ model: MLXModelInfo, from base: URL) async throws -> any LLMClient {
        #if targetEnvironment(simulator)
        throw MLXUnsupportedOnSimulator()
        #else
        Memory.cacheLimit = 64 * 1024 * 1024
        let container = try await loadModelContainer(
            hub: HubApi(downloadBase: base),
            configuration: ModelConfiguration(id: model.id, revision: model.revision),
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

    func load(_ model: MLXModelInfo) async {
        if state == .loaded, loadedModelID == model.id { return }
        dropClient()
        generation += 1
        let current = generation
        state = .loading
        let start = ContinuousClock.now
        do {
            let loaded = try await loader.load(model, from: store.baseDirectory)
            guard current == generation else { return }
            client = loaded
            loadedModelID = model.id
            lastLoadSeconds = Self.seconds(ContinuousClock.now - start)
            state = .loaded
        } catch {
            guard current == generation else { return }
            dropClient()
            state = .failed(Self.loadFailedText)
        }
    }

    func unload() {
        generation += 1
        dropClient()
        state = .idle
    }

    func handleMemoryWarning() {
        guard state == .loaded || state == .loading else { return }
        unload()
        state = .unloadedForMemory
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
