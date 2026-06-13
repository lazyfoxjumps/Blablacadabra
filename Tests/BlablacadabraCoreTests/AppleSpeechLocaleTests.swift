import Foundation
import Testing
@testable import BlablacadabraCore

/// Pure locale-mapping for the Apple SpeechAnalyzer path. The live OS calls
/// (`isSupported`, `requestAuthorization`, and the analyzer itself) are
/// integration-only (gotcha 21); these cover the deterministic mapping that
/// `AppState`'s engine selection relies on.
@Suite struct AppleSpeechLocaleTests {
    @Test func lockedSpokenLanguageWins() {
        // A locked non-English language is used verbatim, ignoring the English
        // variant entirely.
        let locale = AppleSpeechLocale.resolved(spokenLanguage: "ja", englishLocale: .us)
        #expect(locale.language.languageCode?.identifier == "ja")
    }

    @Test func unlockedFallsBackToChosenEnglishVariant() {
        // nil lock = assume English, in the user's chosen variant.
        #expect(AppleSpeechLocale.resolved(spokenLanguage: nil, englishLocale: .au).identifier(.bcp47) == "en-AU")
        #expect(AppleSpeechLocale.resolved(spokenLanguage: nil, englishLocale: .uk).identifier(.bcp47) == "en-GB")
    }

    @Test func emptyLockIsTreatedAsUnlocked() {
        // An empty string is "auto", same as nil (matches TranscriptionPipeline).
        #expect(AppleSpeechLocale.resolved(spokenLanguage: "", englishLocale: .us).identifier(.bcp47) == "en-US")
    }

    @Test func everyEnglishVariantMapsToItsLocaleIdentifier() {
        for variant in EnglishLocale.allCases {
            let locale = AppleSpeechLocale.resolved(spokenLanguage: nil, englishLocale: variant)
            #expect(locale.identifier(.bcp47) == variant.localeIdentifier)
        }
    }

    @Test func isoCodeStripsRegion() {
        #expect(AppleSpeechLocale.isoCode(for: Locale(identifier: "en-GB")) == "en")
        #expect(AppleSpeechLocale.isoCode(for: Locale(identifier: "ja-JP")) == "ja")
        #expect(AppleSpeechLocale.isoCode(for: Locale(identifier: "ja")) == "ja")
    }
}
