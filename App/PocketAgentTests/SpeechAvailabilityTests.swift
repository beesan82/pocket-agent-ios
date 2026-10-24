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

    @Test func reasonOrderWithEnglish() {
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: false, permissionGranted: false,
                supportsEnglish: false, englishAssetsInstalled: false)
                == .englishUnsupported)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: false, permissionGranted: false,
                supportsEnglish: true, englishAssetsInstalled: false)
                == .assetsNotInstalled)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: true, permissionGranted: false,
                supportsEnglish: true, englishAssetsInstalled: false)
                == .englishAssetsNotInstalled)
        #expect(
            SpeechAvailability.reason(
                isAvailable: true, supportsJapanese: true, assetsInstalled: true, permissionGranted: true,
                supportsEnglish: true, englishAssetsInstalled: true)
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
            .moduleUnavailable, .japaneseUnsupported, .englishUnsupported, .assetsNotInstalled,
            .englishAssetsNotInstalled, .permissionDenied,
        ]
        #expect(Set(reasons.map(\.userMessage)).count == reasons.count)
        #expect(reasons.allSatisfy { !$0.userMessage.isEmpty })
    }
}
