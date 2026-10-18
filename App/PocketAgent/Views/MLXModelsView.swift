import PocketAgentCore
import SwiftUI

/// Phase 2: MLX model list — user-initiated download, progress, cancel, delete, selection.
struct MLXModelsView: View {
    let store: MLXModelStore
    let measurementLog: MeasurementLog

    @State private var probe = NetworkCostProbe()
    @State private var pendingDownload: PendingDownload?
    @State private var pendingDelete: MLXModelInfo?
    @State private var message: String?
    @State private var downloadStarts: [String: ContinuousClock.Instant] = [:]

    private struct PendingDownload: Identifiable {
        let model: MLXModelInfo
        let isExpensive: Bool
        let freeBytes: Int64
        var id: String { model.id }
    }

    var body: some View {
        List {
            ForEach(MLXModelRegistry.all) { model in
                row(model)
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("モデル管理")
        .task { store.refresh() }
        .onChange(of: statusSnapshot) { old, new in logDownloadTransitions(from: old, to: new) }
        .confirmationDialog(
            "ダウンロードしますか？",
            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
            titleVisibility: .visible,
            presenting: pendingDownload
        ) { pending in
            Button("ダウンロード") { start(pending) }
            Button("キャンセル", role: .cancel) {}
        } message: { pending in
            Text(confirmationText(pending))
        }
        .confirmationDialog(
            "モデルを削除しますか？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { model in
            Button("削除", role: .destructive) {
                store.delete(model)
                measurementLog.append("モデル削除: \(model.displayName)")
            }
            Button("キャンセル", role: .cancel) {}
        } message: { model in
            Text("\(model.displayName) を端末から削除します。")
        }
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
            Text("約 \(Self.megabytes(model.approxBytes))・\(model.license)")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.notes).font(.caption).foregroundStyle(.secondary)
            statusView(status)
            actions(model, status: status)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusView(_ status: MLXModelStore.Status) -> some View {
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

    @ViewBuilder
    private func actions(_ model: MLXModelInfo, status: MLXModelStore.Status) -> some View {
        HStack {
            switch status {
            case .notDownloaded, .failed:
                Button("ダウンロード") { prepareDownload(model) }
            case .downloading:
                Button("中断", role: .destructive) {
                    store.cancelDownload()
                    measurementLog.append(
                        "モデルダウンロード中断: \(model.displayName)" + elapsedText(model))
                    downloadStarts[model.id] = nil
                }
            case .downloaded:
                Button(store.selected == model ? "選択中" : "選択") { store.selected = model }
                    .disabled(store.selected == model)
                Button("削除", role: .destructive) { pendingDelete = model }
            }
        }
        .buttonStyle(.bordered)
    }

    private func prepareDownload(_ model: MLXModelInfo) {
        message = nil
        // Unreadable free space is treated as zero: refuse rather than fill the disk.
        pendingDownload = PendingDownload(
            model: model, isExpensive: probe.isExpensive, freeBytes: DeviceProbes.freeDiskBytes() ?? 0)
    }

    private func start(_ pending: PendingDownload) {
        // The user has just confirmed (including the cellular warning), so no second confirmation.
        switch store.startDownload(pending.model, freeBytes: pending.freeBytes, isExpensiveNetwork: false) {
        case .started:
            message = nil
            downloadStarts[pending.model.id] = ContinuousClock.now
            measurementLog.append(
                "モデルダウンロード開始: \(pending.model.displayName) 約 \(Self.megabytes(pending.model.approxBytes))")
        case let .refusedDiskSpace(requiredBytes):
            message = ModelUnavailableReason.insufficientDiskSpace(requiredBytes: requiredBytes).userMessage
        case .needsConfirmation:
            message = nil
        case .busy:
            message = "別のダウンロードが進行中です"
        }
    }

    private func confirmationText(_ pending: PendingDownload) -> String {
        var lines = [
            pending.model.displayName,
            "約 \(Self.megabytes(pending.model.approxBytes))",
            "ライセンス: \(pending.model.license)",
            "通信が発生します",
        ]
        if pending.isExpensive { lines.append("Wi-Fi の利用を推奨します") }
        return lines.joined(separator: "\n")
    }

    /// Statuses of every model, so `onChange` sees downloading to downloaded / failed.
    private var statusSnapshot: [MLXModelStore.Status] {
        MLXModelRegistry.all.map { store.status(of: $0) }
    }

    private func logDownloadTransitions(from old: [MLXModelStore.Status], to new: [MLXModelStore.Status]) {
        for (index, model) in MLXModelRegistry.all.enumerated() where index < old.count && index < new.count {
            guard case .downloading = old[index] else { continue }
            switch new[index] {
            case .downloaded:
                measurementLog.append(
                    "モデルダウンロード完了: \(model.displayName) \(Self.megabytes(model.approxBytes))"
                        + elapsedText(model))
                downloadStarts[model.id] = nil
            case .failed:
                measurementLog.append("モデルダウンロード失敗: \(model.displayName)" + elapsedText(model))
                downloadStarts[model.id] = nil
            case .notDownloaded, .downloading:
                break
            }
        }
    }

    private func elapsedText(_ model: MLXModelInfo) -> String {
        guard let start = downloadStarts[model.id] else { return "" }
        let parts = (ContinuousClock.now - start).components
        return String(format: " / 経過 %.0f 秒", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}
