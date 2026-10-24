import Testing
@testable import PocketAgent

struct SpeechAvailabilityTests {
    @Test func reasonOrder() {
        #expect(
            SpeechAvailability.reason(
                isAvailable: false, supportsJapanese: false, assetsInstalled: false, permissionGranted: false)
                == .moduleUnavailable)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: false, assetsInstalled: false, permissionGranted: false)
                == .japaneseUnsupported)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: false, permissionGranted: false)
                == .assetsNotInstalled)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: true, permissionGranted: false)
                == .permissionDenied)
    }

    private func status(_ code: String, _ name: String, supported: Bool = true, installed: Bool = true)
        -> SpeechAvailability.LanguageStatus
    {
        SpeechAvailability.LanguageStatus(code: code, name: name, supported: supported, installed: installed)
    }

    @Test func reasonOrderWithSeveralLanguages() {
        #expect(
            SpeechAvailability.reason(
                isAvailable: true,
                languages: [status("ja", "日本語", installed: false), status("zh", "中文", supported: false, installed: false)],
                permissionGranted: false)
                == .languageUnsupported("中文"))
        #expect(
            SpeechAvailability.reason(
                isAvailable: true,
                languages: [status("ja", "日本語", installed: false), status("en", "English", installed: false)],
                permissionGranted: false)
                == .assetsNotInstalled)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, languages: [status("en", "English"), status("zh", "中文", installed: false)],
                permissionGranted: false)
                == .languageAssetsNotInstalled("中文"))
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, languages: [status("en", "English"), status("zh", "中文")], permissionGranted: true)
                == nil)
    }

    @Test func allGoodGivesNil() {
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: true, permissionGranted: true)
                == nil)
    }

    @Test func messagesAreJapaneseAndDistinct() {
        let reasons: [SpeechUnavailableReason] = [
            .moduleUnavailable, .japaneseUnsupported, .languageUnsupported("中文"), .assetsNotInstalled,
            .languageAssetsNotInstalled("中文"), .permissionDenied,
        ]
        #expect(Set(reasons.map(\.userMessage)).count == reasons.count)
        #expect(reasons.allSatisfy { !$0.userMessage.isEmpty })
    }
}
