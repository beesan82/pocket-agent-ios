import Foundation
import Network
import os
#if !targetEnvironment(simulator)
import MLX
#endif

/// Small readers for the validation / model screens. Nothing here can crash on the simulator.
enum DeviceProbes {
    /// Free space the system is willing to give to important downloads; nil if unreadable.
    static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// MLX active memory in bytes. Never touches MLX on the simulator.
    static func mlxActiveMemoryBytes() -> Int64? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return Int64(Memory.activeMemory)
        #endif
    }

    /// Bytes this process may still allocate (0 on the simulator).
    static func availableMemoryBytes() -> Int64 {
        Int64(os_proc_available_memory())
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

/// Watches the network path so the download confirmation can warn about cellular data.
/// The path is read once, when the user taps download.
final class NetworkCostProbe: @unchecked Sendable {
    private let monitor = NWPathMonitor()

    init() {
        monitor.start(queue: DispatchQueue(label: "pocketagent.networkcost"))
    }

    deinit { monitor.cancel() }

    var isExpensive: Bool { monitor.currentPath.isExpensive }
}
