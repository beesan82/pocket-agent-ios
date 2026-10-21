import AgentRunKit
import AgentRunKitFoundationModels
import PocketAgentCore
import PocketAgentRuntime
import SwiftUI

/// The on-device model as the journal screens see it. "Ready" means a usable client: Apple's at once,
/// the downloaded model's once loaded. The `store:runtime:` forms are the downloaded model only (the chat uses them).
@MainActor
enum JournalModelAccess {
    /// 今週/先週 start on Monday, in the device's time zone.
    static var journalCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    static func assistant(client: any LLMClient, backend: JournalBackend) -> JournalAssistant {
        JournalAssistant(
            client: client, calendar: journalCalendar,
            contextCharacterBudget: JournalModelRule.contextCharacterBudget(for: backend))
    }

    /// Follows Settings: Apple when chosen and usable, otherwise the downloaded model. Never Claude.
    static func backend(settings: ModelSettings, availability: any ModelAvailabilityChecking) -> JournalBackend {
        JournalModelRule.backend(choice: settings.choice, availability: availability)
    }

    /// Apple is chosen but cannot be used here, so the journal runs on the downloaded model.
    static func usesDownloadedInsteadOfApple(settings: ModelSettings, backend: JournalBackend) -> Bool {
        settings.choice == .appleLocal && backend == .mlxLocal
    }

    static func reason(_ backend: JournalBackend, store: MLXModelStore, runtime: MLXRuntime) -> ModelUnavailableReason? {
        switch backend {
        case .appleLocal: nil
        case .mlxLocal: reason(store: store, runtime: runtime)
        }
    }

    static func readyClient(_ backend: JournalBackend, store: MLXModelStore, runtime: MLXRuntime) -> (any LLMClient)? {
        switch backend {
        case .appleLocal: return appleClient()
        case .mlxLocal: return readyClient(store: store, runtime: runtime)
        }
    }

    static func isReady(_ backend: JournalBackend, store: MLXModelStore, runtime: MLXRuntime) -> Bool {
        switch backend {
        case .appleLocal: true
        case .mlxLocal: readyClient(store: store, runtime: runtime) != nil
        }
    }

    static func client(_ backend: JournalBackend, store: MLXModelStore, runtime: MLXRuntime) async -> (any LLMClient)? {
        switch backend {
        case .appleLocal: return appleClient()
        case .mlxLocal: return await client(store: store, runtime: runtime)
        }
    }

    /// No tools: the journal sends single-turn system + user prompts.
    private static func appleClient() -> any LLMClient {
        FoundationModelsClient<EmptyContext>(tools: [], context: EmptyContext())
    }

    static func reason(store: MLXModelStore, runtime: MLXRuntime) -> ModelUnavailableReason? {
        MLXAvailability.reason(state: runtime.state, status: store.status(of: store.selected))
    }

    /// The loaded client, only when it is the selected model's (a stale one is never reused).
    static func readyClient(store: MLXModelStore, runtime: MLXRuntime) -> (any LLMClient)? {
        runtime.loadedModelID == store.selected.id ? runtime.client : nil
    }

    /// The loaded client; loads the selected model first when it is downloaded but not loaded.
    /// Never loads on the simulator or for a model that is not downloaded.
    static func client(store: MLXModelStore, runtime: MLXRuntime) async -> (any LLMClient)? {
        if let client = readyClient(store: store, runtime: runtime) { return client }
        switch reason(store: store, runtime: runtime) {
        case nil, .modelLoading?:
            await runtime.load(store.selected)
            return runtime.client
        default:
            return nil
        }
    }
}

/// Model status for the journal screens: loading, why it cannot be used, and the way to fix it.
struct JournalModelStatusView: View {
    let store: MLXModelStore
    let runtime: MLXRuntime
    let measurementLog: MeasurementLog
    /// False inside a sheet: the models screen cannot present its confirmations there.
    var linksToModelManagement = true
    /// Apple needs no download or load, so there is nothing to show for it.
    var backend: JournalBackend = .mlxLocal
    /// Apple was chosen but is not usable here.
    var showsAppleFallbackNote = false

    var body: some View {
        // No wrapping stack: in a Form an empty stack would still draw a row.
        if backend == .mlxLocal {
            if showsAppleFallbackNote {
                Text("Apple は使えないため、ダウンロードモデルを使います")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            downloadedModelStatus
        }
    }

    @ViewBuilder
    private var downloadedModelStatus: some View {
        if JournalModelAccess.readyClient(store: store, runtime: runtime) != nil {
            EmptyView()
        } else if runtime.state == .loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("モデルを読み込み中…")
            }
            .foregroundStyle(.secondary)
        } else if let reason = JournalModelAccess.reason(store: store, runtime: runtime) {
            VStack(alignment: .leading, spacing: 6) {
                Text(reason.userMessage).font(.footnote).foregroundStyle(.secondary)
                switch reason {
                case .modelNotDownloaded:
                    if linksToModelManagement {
                        NavigationLink("モデル管理") {
                            MLXModelsView(store: store, measurementLog: measurementLog)
                        }
                    } else {
                        Text("設定タブの「ローカル（端末内）」でダウンロードしてください")
                            .font(.footnote)
                    }
                case .unloadedForMemory:
                    loadButton
                default:
                    EmptyView()
                }
            }
        } else if case let .failed(text) = runtime.state {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote).foregroundStyle(.secondary)
                loadButton
            }
        }
    }

    private var loadButton: some View {
        Button("モデルを読み込む") {
            let model = store.selected
            Task { await runtime.load(model) }
        }
    }
}

/// Ends on-device generation when the app leaves the foreground (GPU work in the background can be
/// killed) or when the model is unloaded for memory. The caller's `stop` keeps what was written so far.
struct StopsJournalGeneration: ViewModifier {
    let runtime: MLXRuntime
    let stop: @MainActor () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var inactiveStop: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                inactiveStop?.cancel()
                inactiveStop = nil
                switch phase {
                case .background:
                    stop()
                case .inactive:
                    // Brief .inactive passes (notification banner, app switcher swipe) are left alone.
                    inactiveStop = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        stop()
                    }
                default:
                    break
                }
            }
            .onChange(of: runtime.state) { _, state in
                if state == .unloadedForMemory { stop() }
            }
            .onDisappear {
                inactiveStop?.cancel()
                inactiveStop = nil
            }
    }
}

extension View {
    func stopsJournalGeneration(runtime: MLXRuntime, stop: @escaping @MainActor () -> Void) -> some View {
        modifier(StopsJournalGeneration(runtime: runtime, stop: stop))
    }
}
