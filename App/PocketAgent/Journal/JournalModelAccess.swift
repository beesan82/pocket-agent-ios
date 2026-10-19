import AgentRunKit
import PocketAgentCore
import SwiftUI

/// The on-device model as the journal screens see it. "Ready" means a loaded client.
@MainActor
enum JournalModelAccess {
    static var journalCalendar: Calendar { Calendar.current }

    static func reason(store: MLXModelStore, runtime: MLXRuntime) -> ModelUnavailableReason? {
        MLXAvailability.reason(state: runtime.state, status: store.status(of: store.selected))
    }

    /// The loaded client; loads the selected model first when it is downloaded but not loaded.
    /// Never loads on the simulator or for a model that is not downloaded.
    static func client(store: MLXModelStore, runtime: MLXRuntime) async -> (any LLMClient)? {
        if let client = runtime.client { return client }
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

    var body: some View {
        if runtime.client != nil {
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
                    NavigationLink("モデル管理") {
                        MLXModelsView(store: store, measurementLog: measurementLog)
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
