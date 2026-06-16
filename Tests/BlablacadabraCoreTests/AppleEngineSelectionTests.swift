import Foundation
import Testing
@testable import BlablacadabraCore

/// The pure engine-selection truth table `AppState` relies on to pick between the
/// Apple `SpeechAnalyzer` transcribe fast-path, the WhisperKit-transcribe +
/// Apple-text-translate path, and the WhisperKit fallback. The live availability /
/// install / authorization probes that feed it are integration-only (gotcha 21);
/// this covers the deterministic decision once those booleans are known.
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
        // Translate on + a locked source language + an installed source->English
        // pack -> Whisper transcribes, Apple text-translates.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true
            ) == .whisperAppleTranslate
        )
    }

    @Test func translateIgnoresAppleSpeechSupportAndAuth() {
        // The translate path uses WhisperKit for transcription, so it needs neither
        // Apple speech-locale support nor the Speech permission. Only the macOS 26
        // Translation framework + a locked, installed, non-denylisted pair matter.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: false, // no Apple speech support
                authorized: false,      // Speech permission denied
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true,
                sourceISOCode: "ar"
            ) == .whisperAppleTranslate
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
        // id is on the denylist (Apple leans Malay) -> Whisper audio-translates it,
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
        // A non-denylisted source still gets the Whisper-transcribe + Apple-translate path.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: true,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true,
                sourceISOCode: "ja"
            ) == .whisperAppleTranslate
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

    @Test func unauthorizedForcesWhisperOnlyForTranscribe() {
        // Transcribe path: a denied Speech permission falls back silently (Apple
        // transcription needs it).
        #expect(
            CaptionEngineKind.select(
                translate: false,
                localeSupported: true,
                authorized: false,
                osHasApple: true
            ) == .whisper
        )
        // Translate path: a denied Speech permission does NOT force Whisper, because
        // WhisperKit (not SpeechAnalyzer) does the transcription here.
        #expect(
            CaptionEngineKind.select(
                translate: true,
                localeSupported: true,
                authorized: false,
                osHasApple: true,
                languageLocked: true,
                translationInstalled: true
            ) == .whisperAppleTranslate
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
        // Everything needs osHasApple (macOS 26). Then:
        // - translate OFF -> appleTranscribe iff (authorized && localeSupported),
        //   else whisper.
        // - translate ON  -> whisperAppleTranslate iff (languageLocked &&
        //   translationInstalled && source not denylisted), else whisper. The
        //   translate path ignores authorized/localeSupported (Whisper transcribes).
        // "ja" stands in for any non-denylisted source, "id" for a denylisted one,
        // nil for "unknown / don't care".
        for translate in [false, true] {
            for localeSupported in [false, true] {
                for authorized in [false, true] {
                    for osHasApple in [false, true] {
                        for languageLocked in [false, true] {
                            for translationInstalled in [false, true] {
                                for sourceISOCode in [nil, "ja", "id"] as [String?] {
                                    let denylisted = sourceISOCode.map(CaptionEngineKind.appleTranslateDenylist.contains) ?? false
                                    let expected: CaptionEngineKind
                                    if !osHasApple {
                                        expected = .whisper
                                    } else if translate {
                                        expected = (languageLocked && translationInstalled && !denylisted) ? .whisperAppleTranslate : .whisper
                                    } else {
                                        expected = (authorized && localeSupported) ? .appleTranscribe : .whisper
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
