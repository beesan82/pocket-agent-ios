import PocketAgentCore
import SwiftUI

/// Download / delete flow of the downloaded models, shared by Settings and the model management
/// screen: confirmation (size, license, cellular warning), free-space check, log lines, messages.
@MainActor
@Observable
final class ModelDownloadFlow {
    struct PendingDownload: Identifiable {
        let model: MLXModelInfo
        let isExpensive: Bool
        let freeBytes: Int64
        var id: String { model.id }
    }

    let store: MLXModelStore
    let measurementLog: MeasurementLog

    var pendingDownload: PendingDownload?
    var pendingDelete: MLXModelInfo?
    var message: String?

    @ObservationIgnored private let probe = NetworkCostProbe()
    @ObservationIgnored private var downloadStarts: [String: ContinuousClock.Instant] = [:]

    init(store: MLXModelStore, measurementLog: MeasurementLog) {
        self.store = store
        self.measurementLog = measurementLog
    }

    func prepareDownload(_ model: MLXModelInfo) {
        message = nil
        // Unreadable free space is treated as zero: refuse rather than fill the disk.
        pendingDownload = PendingDownload(
            model: model, isExpensive: probe.isExpensive, freeBytes: DeviceProbes.freeDiskBytes() ?? 0)
    }

    func start(_ pending: PendingDownload) {
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

    func cancel(_ model: MLXModelInfo) {
        store.cancelDownload()
        measurementLog.append("モデルダウンロード中断: \(model.displayName)" + elapsedText(model))
        downloadStarts[model.id] = nil
    }

    func confirmDelete(_ model: MLXModelInfo) {
        store.delete(model)
        measurementLog.append("モデル削除: \(model.displayName)")
    }

    func confirmationText(_ pending: PendingDownload) -> String {
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
    var statusSnapshot: [MLXModelStore.Status] {
        MLXModelRegistry.all.map { store.status(of: $0) }
    }

    func logDownloadTransitions(from old: [MLXModelStore.Status], to new: [MLXModelStore.Status]) {
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

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
}

/// Status line of one model (未ダウンロード / ダウンロード中 N% / ダウンロード済み / failure text).
struct ModelStatusView: View {
    let status: MLXModelStore.Status

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

/// Compact row for Settings: tap selects a downloaded model, or opens the download confirmation.
struct DownloadModelRow: View {
    let model: MLXModelInfo
    let flow: ModelDownloadFlow
    let isChosen: Bool
    let onSelect: () -> Void

    private var isDownloading: Bool {
        if case .downloading = flow.store.status(of: model) { return true }
        return false
    }

    var body: some View {
        let status = flow.store.status(of: model)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                switch status {
                case .downloaded: onSelect()
                case .notDownloaded, .failed: flow.prepareDownload(model)
                case .downloading: break
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        Text("約 \(ModelDownloadFlow.megabytes(model.approxBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isChosen {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                            .accessibilityLabel("選択中")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
            ModelStatusView(status: status)
            if isDownloading {
                Button("中断", role: .destructive) { flow.cancel(model) }
                    .buttonStyle(.bordered)
            }
        }
        .swipeActions(edge: .trailing) {
            if status == .downloaded {
                Button("削除", role: .destructive) { flow.pendingDelete = model }
            }
        }
    }
}

private struct ModelDownloadDialogs: ViewModifier {
    @Bindable var flow: ModelDownloadFlow

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "ダウンロードしますか？",
                isPresented: Binding(
                    get: { flow.pendingDownload != nil }, set: { if !$0 { flow.pendingDownload = nil } }),
                titleVisibility: .visible,
                presenting: flow.pendingDownload
            ) { pending in
                Button("ダウンロード") { flow.start(pending) }
                Button("キャンセル", role: .cancel) {}
            } message: { pending in
                Text(flow.confirmationText(pending))
            }
            .confirmationDialog(
                "モデルを削除しますか？",
                isPresented: Binding(
                    get: { flow.pendingDelete != nil }, set: { if !$0 { flow.pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: flow.pendingDelete
            ) { model in
                Button("削除", role: .destructive) { flow.confirmDelete(model) }
                Button("キャンセル", role: .cancel) {}
            } message: { model in
                Text("\(model.displayName) を端末から削除します。")
            }
    }
}

extension View {
    func modelDownloadDialogs(_ flow: ModelDownloadFlow) -> some View {
        modifier(ModelDownloadDialogs(flow: flow))
    }
}
