import Foundation
import Observation
import Security
import os
#if !targetEnvironment(simulator)
import MLX
#endif

/// Timestamped event log shown on screen and copied as text for the verification sheet.
@MainActor @Observable
final class SpikeLog {
    private(set) var lines: [String] = []
    private let start = Date()

    func add(_ message: String) {
        let elapsed = String(format: "%7.2f", Date().timeIntervalSince(start))
        lines.append("[\(elapsed)s] \(message)")
    }

    var text: String { lines.joined(separator: "\n") }
    func clear() { lines.removeAll(); summaries.removeAll() }

    /// One short line per experiment, so the copy fits TestFlight's 400-character comment.
    private(set) var summaries: [String] = []
    func addSummary(_ line: String) { summaries.append(line); add("結果 " + line) }
    var summaryText: String { summaries.joined(separator: "\n") }
}

/// Spike-only note store (in memory). The spike checks that the tool runs, not persistence.
@MainActor @Observable
final class NoteBox {
    private(set) var notes: [String] = []
    func append(_ text: String) { notes.append(text) }
}

/// Approval wait inside `Tool.call` (Foundation Models has no pre-execution hook).
/// Cancelling the waiting task resolves the request as "not approved".
@MainActor @Observable
final class ApprovalCenter {
    struct Request: Identifiable {
        let id = UUID()
        let toolName: String
        let summary: String
    }

    private(set) var request: Request?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Experiments only: approve without showing the sheet (logged by the tool).
    var autoApprove = false

    func ask(toolName: String, summary: String) async -> Bool {
        if autoApprove { return true }
        guard continuation == nil else { return false }  // one approval at a time
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.request = Request(toolName: toolName, summary: summary)
            }
        } onCancel: {
            Task { @MainActor in self.resolve(false) }
        }
    }

    func resolve(_ approved: Bool) {
        request = nil
        continuation?.resume(returning: approved)
        continuation = nil
    }
}

/// Reads / writes the same Keychain item Pocket Agent uses (same bundle ID → same access group).
enum SpikeKeychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.beesan82.pocketagent.anthropic",
        kSecAttrAccount as String: "api-key",
    ] }

    static func readAPIKey() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String) -> OSStatus {
        let update: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
    }
}

enum Probes {
    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func memorySummary() -> String {
        let available = Double(os_proc_available_memory()) / 1_048_576
        #if targetEnvironment(simulator)
        return String(format: "available %.0f MB (simulator)", available)
        #else
        let active = Double(Memory.activeMemory) / 1_048_576
        return String(format: "MLX active %.0f MB, available %.0f MB", active, available)
        #endif
    }
}
