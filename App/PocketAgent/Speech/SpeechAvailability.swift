/// Why on-device Japanese speech input cannot be used right now (nil = usable).
enum SpeechUnavailableReason: Equatable {
    case moduleUnavailable
    case japaneseUnsupported
    case englishUnsupported
    case assetsNotInstalled
    case englishAssetsNotInstalled
    case permissionDenied

    var userMessage: String {
        switch self {
        case .moduleUnavailable:
            "この端末では音声入力を利用できません。"
        case .japaneseUnsupported:
            "この端末では日本語の音声入力に対応していません。"
        case .englishUnsupported:
            "この端末では英語の音声入力に対応していません。"
        case .assetsNotInstalled:
            "日本語の音声認識データが未インストールです。「音声データを入手」をタップしてください。"
        case .englishAssetsNotInstalled:
            "英語の音声認識データが未インストールです。「音声データを入手」をタップしてください。"
        case .permissionDenied:
            "マイクまたは音声認識が許可されていません。設定アプリで許可してください。"
        }
    }
}

enum SpeechAvailability {
    /// Returns the first failing check: module, language support (ja, en), assets (ja, en), permission.
    /// The English checks only matter for a bilingual capture; they default to passing.
    static func reason(
        isAvailable: Bool, supportsJapanese: Bool, assetsInstalled: Bool, permissionGranted: Bool,
        supportsEnglish: Bool = true, englishAssetsInstalled: Bool = true
    ) -> SpeechUnavailableReason? {
        if !isAvailable { return .moduleUnavailable }
        if !supportsJapanese { return .japaneseUnsupported }
        if !supportsEnglish { return .englishUnsupported }
        if !assetsInstalled { return .assetsNotInstalled }
        if !englishAssetsInstalled { return .englishAssetsNotInstalled }
        if !permissionGranted { return .permissionDenied }
        return nil
    }
}
