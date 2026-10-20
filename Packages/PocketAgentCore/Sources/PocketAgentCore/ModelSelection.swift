import Foundation

/// Which model answers (FR-02). The raw value is persisted; it is not a secret.
public enum ModelChoice: String, Sendable, CaseIterable, Codable {
    case claude
    case appleLocal
    case mlxLocal

    /// Runs on the device: the conversation never goes to the cloud.
    public var isLocal: Bool { self != .claude }

    public var displayName: String {
        switch self {
        case .claude: "Claude（クラウド）"
        case .appleLocal: "Appleローカル（端末内）"
        case .mlxLocal: "ダウンロードモデル（端末内）"
        }
    }
}

/// Why a model cannot be used right now (FR-03). Shown to the user as is.
public enum ModelUnavailableReason: Sendable, Equatable {
    case missingAPIKey
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedOS
    case simulatorUnsupported
    case modelNotDownloaded
    case modelLoading
    case insufficientDiskSpace(requiredBytes: Int64)
    case unloadedForMemory
    case unknown(String)

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            "Claude APIキーが保存されていません。設定画面で入力してください。"
        case .deviceNotEligible:
            "この端末はApple Intelligenceに対応していません。"
        case .appleIntelligenceNotEnabled:
            "Apple Intelligenceがオフです。設定アプリでオンにしてください。"
        case .modelNotReady:
            "端末内モデルを準備中です（ダウンロード中など）。しばらくしてから再試行してください。"
        case .unsupportedOS:
            "このiOSバージョンでは端末内モデルを利用できません。"
        case .simulatorUnsupported:
            "シミュレータでは端末内モデルを利用できません"
        case .modelNotDownloaded:
            "モデルが未ダウンロードです。設定のモデル管理からダウンロードしてください"
        case .modelLoading:
            "モデルを読み込み中です"
        case let .insufficientDiskSpace(requiredBytes):
            "空き容量が不足しています（必要: 約 \(String(format: "%.1f", Double(requiredBytes) / 1_000_000_000)) GB）"
        case .unloadedForMemory:
            "メモリ不足のためモデルを解放しました。もう一度読み込んでください"
        case let .unknown(detail):
            "端末内モデルを利用できません（\(detail)）。"
        }
    }
}

/// Where the Claude API key lives. The app uses the Keychain; nothing else may hold the key.
public protocol CredentialStore: Sendable {
    func readAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

public protocol ModelAvailabilityChecking: Sendable {
    /// `nil` means the on-device model can be used now.
    func appleLocalUnavailableReason() -> ModelUnavailableReason?
}

public enum ModelResolutionError: Error, Sendable, Equatable {
    case unavailable(ModelUnavailableReason)
    case credentialReadFailed
    case clientCreationFailed
}

/// Turns the user's model choice into a client, keeping the two paths apart:
/// - `.appleLocal` never reads the API key nor builds a Claude client (AT-14)
/// - an unavailable on-device model is reported, never replaced by Claude (AT-03)
///
/// Generic over `Backend` so this stays free of AgentRunKit.
public struct ModelBackendResolver<Backend>: Sendable {
    private let credentials: any CredentialStore
    private let availability: any ModelAvailabilityChecking
    private let makeClaude: @Sendable (String) throws -> Backend
    private let makeAppleLocal: @Sendable () throws -> Backend

    public init(
        credentials: any CredentialStore,
        availability: any ModelAvailabilityChecking,
        makeClaude: @escaping @Sendable (String) throws -> Backend,
        makeAppleLocal: @escaping @Sendable () throws -> Backend
    ) {
        self.credentials = credentials
        self.availability = availability
        self.makeClaude = makeClaude
        self.makeAppleLocal = makeAppleLocal
    }

    public func resolve(_ choice: ModelChoice) -> Result<Backend, ModelResolutionError> {
        switch choice {
        case .mlxLocal:
            // The MLX chat path has its own entry point; this resolver never serves it
            // and must not read the Claude key on its behalf.
            return .failure(.unavailable(.modelNotDownloaded))
        case .appleLocal:
            if let reason = availability.appleLocalUnavailableReason() {
                return .failure(.unavailable(reason))
            }
            return build(makeAppleLocal)
        case .claude:
            let stored: String?
            do {
                stored = try credentials.readAPIKey()
            } catch {
                return .failure(.credentialReadFailed)
            }
            let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else {
                return .failure(.unavailable(.missingAPIKey))
            }
            return build { try makeClaude(key) }
        }
    }

    private func build(_ make: () throws -> Backend) -> Result<Backend, ModelResolutionError> {
        do {
            return try .success(make())
        } catch {
            return .failure(.clientCreationFailed)
        }
    }
}
