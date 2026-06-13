import Foundation
import Testing
@testable import BlablacadabraCore

/// The pure engine-selection truth table `AppState` relies on to pick the Apple
/// `SpeechAnalyzer` fast-path vs the WhisperKit fallback. The live availability
/// and authorization probes that feed it are integration-only (gotcha 21); this
/// covers the deterministic decision once those booleans are known.
@Suite struct AppleEngineSelectionTests {
    @Test func appleChosenOnlyWhenEverythingHolds() {
        // The one happy path: not translating, OS has the API, locale supported,
        // and authorized -> Apple.
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: true,
                authorized: true,
                osHasApple: true
            ) == .apple
        )
    }

    @Test func translateForcesWhisper() {
        // Round 1 keeps translate on WhisperKit even when Apple is otherwise ready.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true
            ) == .whisper
        )
    }

    @Test func unsupportedLocaleForcesWhisper() {
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: false,
                authorized: true,
                osHasApple: true
            ) == .whisper
        )
    }

    @Test func unauthorizedForcesWhisper() {
        // A denied Speech permission falls back silently.
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: true,
                authorized: false,
                osHasApple: true
            ) == .whisper
        )
    }

    @Test func oldOSForcesWhisper() {
        // No macOS 26 Apple API -> WhisperKit only, even if every other flag is set.
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: true,
                authorized: true,
                osHasApple: false
            ) == .whisper
        )
    }

    @Test func anySingleMissForcesWhisper() {
        // Exhaustive over the four booleans: Apple iff (no translate, supported,
        // authorized, osHasApple); every other combination is WhisperKit.
        for translate in [false, true] {
            for localeSupported in [false, true] {
                for authorized in [false, true] {
                    for osHasApple in [false, true] {
                        let expected: CaptionEngineKind =
                            (!translate && localeSupported && authorized && osHasApple)
                            ? .apple : .whisper
                        #expect(
                            CaptionEngineKind.select(
                                translate: translate,
                                localeSupported: localeSupported,
                                authorized: authorized,
                                osHasApple: osHasApple
                            ) == expected
                        )
                    }
                }
            }
        }
    }
}
