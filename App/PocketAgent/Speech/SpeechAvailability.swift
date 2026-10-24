/// Why on-device speech input cannot be used right now (nil = usable). Japanese keeps its own
/// cases; other languages carry their display name (`MeetingLanguage.displayName`).
enum SpeechUnavailableReason: Equatable {
    case moduleUnavailable
    case japaneseUnsupported
    case languageUnsupported(String)
    case assetsNotInstalled
    case languageAssetsNotInstalled(String)
    case permissionDenied

    var userMessage: String {
        switch self {
        case .moduleUnavailable:
            "この端末では音声入力を利用できません。"
        case .japaneseUnsupported:
            "この端末では日本語の音声入力に対応していません。"
        case let .languageUnsupported(name):
            "この端末では\(name)の音声入力に対応していません。"
        case .assetsNotInstalled:
            "日本語の音声認識データが未インストールです。「音声データを入手」をタップしてください。"
        case let .languageAssetsNotInstalled(name):
            "\(name)の音声認識データが未インストールです。「音声データを入手」をタップしてください。"
        case .permissionDenied:
            "マイクまたは音声認識が許可されていません。設定アプリで許可してください。"
        }
    }
}

enum SpeechAvailability {
    struct LanguageStatus: Equatable {
        let code: String
        let name: String
        let supported: Bool
        let installed: Bool
    }

    /// Japanese only (the original single-language check).
    static func reason(
        isAvailable: Bool, supportsJapanese: Bool, assetsInstalled: Bool, permissionGranted: Bool
    ) -> SpeechUnavailableReason? {
        reason(
            isAvailable: isAvailable,
            languages: [LanguageStatus(code: "ja", name: "日本語", supported: supportsJapanese, installed: assetsInstalled)],
            permissionGranted: permissionGranted)
    }

    /// The first failing check: module, support (in the meeting's language order), assets (same
    /// order), permission.
    static func reason(
        isAvailable: Bool, languages: [LanguageStatus], permissionGranted: Bool
    ) -> SpeechUnavailableReason? {
        if !isAvailable { return .moduleUnavailable }
        if let missing = languages.first(where: { !$0.supported }) {
            return missing.code == "ja" ? .japaneseUnsupported : .languageUnsupported(missing.name)
        }
        if let missing = languages.first(where: { !$0.installed }) {
            return missing.code == "ja" ? .assetsNotInstalled : .languageAssetsNotInstalled(missing.name)
        }
        if !permissionGranted { return .permissionDenied }
        return nil
    }
}
