import Foundation

/// Which on-device engine translates the bilingual meeting (ADR-050). Stored in UserDefaults.
public enum TranslationEngineChoice: String, Sendable, CaseIterable, Codable {
    case apple
    case plamo

    public static let storageKey = "translation.engine"

    public var displayName: String {
        switch self {
        case .apple: "Apple Translation（端末内）"
        case .plamo: "PLaMo 3 Translate（端末内）"
        }
    }
}

/// PFML3 prompt for PLaMo 3 Translate, as in the GGUF chat_template (ADR-050).
/// The BOS token is added by the tokenizer, so it is not part of the string.
public enum PlamoPrompt {
    public static let stopMarkers = ["<|plamo:tag|>", "<|plamo:bos|>"]

    /// nil when the text is blank (ASCII whitespace only), contains a PFML marker (the template
    /// rejects it), or a language code is not like "ja" / "en" / "zh-hans".
    public static func prompt(text: String, source: String, target: String) -> String? {
        let blank: Set<Unicode.Scalar> = [" ", "\t", "\r", "\n"]
        guard !text.unicodeScalars.allSatisfy({ blank.contains($0) }) else { return nil }
        guard !text.contains("<|plamo:") else { return nil }
        let source = source.lowercased()
        let target = target.lowercased()
        guard isLanguageCode(source), isLanguageCode(target) else { return nil }
        return "<|plamo:tag|>dataset<|plamo:msg|>translation"
            + "<|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>\(source)<|plamo:msg|>\(text)"
            + "<|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>\(target)<|plamo:msg|>"
    }

    /// Cuts at the first stop marker and trims surrounding whitespace and newlines.
    public static func cleanedOutput(_ raw: String) -> String {
        let cut = stopMarkers.compactMap { raw.range(of: $0)?.lowerBound }.min() ?? raw.endIndex
        return String(raw[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ^[a-z]{2,3}(-[a-z]{4})?$ on an already lowercased code.
    private static func isLanguageCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        func letters(_ part: Substring) -> Bool {
            part.unicodeScalars.allSatisfy { $0 >= "a" && $0 <= "z" }
        }
        guard (2...3).contains(parts[0].count), letters(parts[0]) else { return false }
        if parts.count == 2 {
            return parts[1].count == 4 && letters(parts[1])
        }
        return true
    }
}

/// Decides which engine can translate right now; never falls back to the other engine silently.
public enum TranslationEngineResolver {
    public enum Resolution: Equatable, Sendable {
        case apple
        case plamo
        case unavailable(UnavailableReason)
    }

    public enum UnavailableReason: Equatable, Sendable {
        case applePairNotInstalled
        case plamoModelNotDownloaded
        case plamoRuntimeUnavailable

        public var userMessage: String {
            switch self {
            case .applePairNotInstalled:
                "翻訳データが未導入です"
            case .plamoModelNotDownloaded:
                "PLaMo 3 Translate のモデルが未ダウンロードです。設定からダウンロードしてください"
            case .plamoRuntimeUnavailable:
                "PLaMo 3 Translate の推論ランタイムが利用できません"
            }
        }
    }

    public static func resolve(
        choice: TranslationEngineChoice, appleInstalled: Bool, plamoDownloaded: Bool, plamoRuntimeAvailable: Bool
    ) -> Resolution {
        switch choice {
        case .apple:
            return appleInstalled ? .apple : .unavailable(.applePairNotInstalled)
        case .plamo:
            guard plamoDownloaded else { return .unavailable(.plamoModelNotDownloaded) }
            guard plamoRuntimeAvailable else { return .unavailable(.plamoRuntimeUnavailable) }
            return .plamo
        }
    }
}
