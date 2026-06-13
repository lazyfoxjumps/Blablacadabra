import Foundation
import Testing
@testable import BlablacadabraCore

/// The pure engine-selection truth table `AppState` relies on to pick between the
/// Apple `SpeechAnalyzer` transcribe fast-path, the Apple transcription + Apple
/// `Translation` path (Round 2), and the WhisperKit fallback. The live
/// availability / install / authorization probes that feed it are integration-only
/// (gotcha 21); this covers the deterministic decision once those booleans are known.
@Suite struct AppleEngineSelectionTests {
    @Test func transcribeChosenWhenEverythingHolds() {
        // Not translating, OS has the API, locale supported, authorized -> Apple
        // transcription. (Lock/install flags don't matter when translate is off.)
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: true,
                authorized: true,
                osHasApple: true
            ) == .appleTranscribe
        )
    }

    @Test func translateChosenWhenLockedAndInstalled() {
        // Round 2: translate on + Apple-supported locale + authorized + a locked
        // source language + an installed source->English pack -> Apple translate.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true
            ) == .appleTranslate
        )
    }

    @Test func translateFallsBackWhenLanguageUnlocked() {
        // No locked language -> Apple can't auto-detect a source; WhisperKit does.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: false,
                translationInstalled: true
            ) == .whisper
        )
    }

    @Test func translateFallsBackWhenPackNotInstalled() {
        // The pair isn't installed and we won't trigger a download -> WhisperKit.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: false
            ) == .whisper
        )
    }

    @Test func translateFallsBackForDenylistedSourceLanguage() {
        // id is on the denylist (Apple leans Malay) -> Whisper translates it,
        // even with a locked + installed pair. Transcribe-only is unaffected.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true,
                sourceISOCode: "id"
            ) == .whisper
        )
        // A non-denylisted source still gets the Apple translate fast-path.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true,
                sourceISOCode: "ja"
            ) == .appleTranslate
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
        // A denied Speech permission falls back silently (both transcribe and
        // translate need it, since both transcribe via Apple).
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: true,
                authorized: false,
                osHasApple: true
            ) == .whisper
        )
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: false,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true
            ) == .whisper
        )
    }

    @Test func oldOSForcesWhisper() {
        // No macOS 26 Apple API -> WhisperKit only, even if every other flag is set.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: false,
                languageLocked: true,
                translationInstalled: true
            ) == .whisper
        )
    }

    @Test func exhaustiveTruthTable() {
        // Apple shared gate: osHasApple && authorized && localeSupported.
        // Then translate off -> appleTranscribe; translate on -> appleTranslate
        // iff (languageLocked && translationInstalled && source not denylisted),
        // else whisper. "ja" stands in for any non-denylisted source, "id" for a
        // denylisted one, nil for "unknown / don't care".
        for translate in [false, true] {
            for localeSupported in [false, true] {
                for authorized in [false, true] {
                    for osHasApple in [false, true] {
                        for languageLocked in [false, true] {
                            for translationInstalled in [false, true] {
                                for sourceISOCode in [nil, "ja", "id"] as [String?] {
                                    let appleGate = osHasApple && authorized && localeSupported
                                    let denylisted = sourceISOCode.map(CaptionEngineKind.appleTranslateDenylist.contains) ?? false
                                    let expected: CaptionEngineKind
                                    if !appleGate {
                                        expected = .whisper
                                    } else if !translate {
                                        expected = .appleTranscribe
                                    } else {
                                        expected = (languageLocked && translationInstalled && !denylisted) ? .appleTranslate : .whisper
                                    }
                                    #expect(
                                        CaptionEngineKind.select(
                                            translate: translate,
                                            localeSupported: localeSupported,
                                            authorized: authorized,
                                            osHasApple: osHasApple,
                                            languageLocked: languageLocked,
                                            translationInstalled: translationInstalled,
                                            sourceISOCode: sourceISOCode
                                        ) == expected
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
