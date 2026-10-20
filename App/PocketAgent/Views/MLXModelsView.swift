import PocketAgentCore
import SwiftUI

/// Phase 2: MLX model list — user-initiated download, progress, cancel, delete, selection.
/// The download / delete flow is shared with Settings (`ModelDownloadFlow`).
struct MLXModelsView: View {
    let store: MLXModelStore
    let measurementLog: MeasurementLog

    @State private var flow: ModelDownloadFlow

    init(store: MLXModelStore, measurementLog: MeasurementLog) {
        self.store = store
        self.measurementLog = measurementLog
        _flow = State(initialValue: ModelDownloadFlow(store: store, measurementLog: measurementLog))
    }

    var body: some View {
        List {
            ForEach(MLXModelRegistry.all) { model in
                row(model)
            }
            if let message = flow.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("モデル管理")
        .task { store.refresh() }
        .modelDownloadDialogs(flow)
    }

    @ViewBuilder
    private func row(_ model: MLXModelInfo) -> some View {
        let status = store.status(of: model)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName).font(.headline)
                Spacer()
                if store.selected == model {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("選択中")
                }
            }
            Text("約 \(ModelDownloadFlow.megabytes(model.approxBytes))・\(model.license)")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.notes).font(.caption).foregroundStyle(.secondary)
            ModelStatusView(status: status)
            actions(model, status: status)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(_ model: MLXModelInfo, status: MLXModelStore.Status) -> some View {
        HStack {
            switch status {
            case .notDownloaded, .failed:
                Button("ダウンロード") { flow.prepareDownload(model) }
            case .downloading:
                Button("中断", role: .destructive) { flow.cancel(model) }
            case .downloaded:
                Button(store.selected == model ? "選択中" : "選択") { store.selected = model }
                    .disabled(store.selected == model)
                Button("削除", role: .destructive) { flow.pendingDelete = model }
            }
        }
        .buttonStyle(.bordered)
    }
}
