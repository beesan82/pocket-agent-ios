/// Why on-device Japanese speech input cannot be used right now (nil = usable).
enum SpeechUnavailableReason: Equatable {
    case moduleUnavailable
    case japaneseUnsupported
    case assetsNotInstalled
    case permissionDenied

    var userMessage: String {
        switch self {
        case .moduleUnavailable:
            "この端末では音声入力を利用できません。"
        case .japaneseUnsupported:
            "この端末では日本語の音声入力に対応していません。"
        case .assetsNotInstalled:
            "日本語の音声認識データが未インストールです。「音声データを入手」をタップしてください。"
        case .permissionDenied:
            "マイクまたは音声認識が許可されていません。設定アプリで許可してください。"
        }
    }
}

enum SpeechAvailability {
    /// Returns the first failing check, in argument order.
    static func reason(
        isAvailable: Bool, supportsJapanese: Bool, assetsInstalled: Bool, permissionGranted: Bool
    ) -> SpeechUnavailableReason? {
        nil  // RED stub
    }
}
