import Foundation
import Testing
@testable import BlablacadabraCore

/// Sweeps EVERY language the spoken-language picker offers through the translate
/// routing + the Turbo->Medium model swap, proving no language can silently produce
/// blank English on Turbo (the bug the user hit on Malay: Turbo can't audio-translate,
/// so any translate session that leans on Whisper audio-translate went blank).
///
/// The decisive invariant, asserted for every language in every translate scenario:
/// a session is NEVER left on a model that can't audio-translate while the route
/// needs it. Pure (no audio, no network) since `select` + `effectiveModel` are pure.
@Suite struct TranslateModelSweepTests {
    /// The model the user reported the bug on: the one that can't audio-translate.
    let turbo = WhisperKitEngine.turboModel

    /// Resolve the engine the way `AppState.resolveEngine` does for a translate
    /// session, then resolve the effective model the way `launchSession` does.
    private func route(iso: String, locked: Bool, installed: Bool)
        -> (engine: CaptionEngineKind, model: String) {
        let engine = CaptionEngineKind.select(
            translate: true,
            localeSupported: false, // unused on the translate path (Whisper transcribes)
            authorized: false,      // unused on the translate path
            osHasApple: true,
            languageLocked: locked,
            translationInstalled: installed,
            sourceISOCode: locked ? iso : nil
        )
        let model = WhisperKitEngine.effectiveModel(
            turbo, engineKind: engine, translate: true, locked: locked
        )
        return (engine, model)
    }

    /// The guarantee: after the swap, the running model can do whatever the route asks.
    private func neverBlank(_ route: (engine: CaptionEngineKind, model: String), locked: Bool) -> Bool {
        !route.engine.needsAudioTranslate(translate: true, locked: locked)
            || WhisperKitEngine.canAudioTranslate(route.model)
    }

    @Test func everyPickerLanguageHasTranslationOnTurbo() {
        for (iso, name) in SpokenLanguage.pickerList {
            // 1. Locked, Apple pack INSTALLED: non-denylisted -> Whisper transcribes +
            //    Apple text-translates (no audio-translate), so Turbo is safe and KEPT
            //    (don't needlessly slow the happy path). Denylisted -> Whisper audio-
            //    translate -> must swap to Medium.
            let lockedInstalled = route(iso: iso, locked: true, installed: true)
            #expect(neverBlank(lockedInstalled, locked: true), "locked+installed blanked for \(name) [\(iso)]")
            if !CaptionEngineKind.appleTranslateDenylist.contains(iso) {
                #expect(lockedInstalled.engine == .whisperAppleTranslate)
                #expect(lockedInstalled.model == turbo, "happy path needlessly left Turbo for \(name)")
            }

            // 2. Locked, pack NOT installed -> Whisper audio-translate -> Turbo unsafe
            //    -> swapped to Medium. (This is the Malay case: ms->en pack absent.)
            let lockedMissing = route(iso: iso, locked: true, installed: false)
            #expect(lockedMissing.engine == .whisper)
            #expect(lockedMissing.model == WhisperKitEngine.mediumModel, "no swap for \(name) [\(iso)]")
            #expect(neverBlank(lockedMissing, locked: true))

            // 3. Auto-detect (unlocked): the per-line Whisper audio-translate fallback
            //    means Turbo is unsafe regardless of language -> swapped to Medium.
            let auto = route(iso: iso, locked: false, installed: false)
            #expect(auto.engine == .whisperAppleTranslate)
            #expect(auto.model == WhisperKitEngine.mediumModel)
            #expect(neverBlank(auto, locked: false))
        }
    }

    /// The exact case the user reported: Malay (ms) locked + translate, Apple pack not
    /// installed. Before the fix this captioned but produced no English on Turbo.
    @Test func malayLockedTranslatesOnTurbo() {
        let r = route(iso: "ms", locked: true, installed: false)
        #expect(r.engine == .whisper)
        #expect(r.model == WhisperKitEngine.mediumModel)
        #expect(WhisperKitEngine.canAudioTranslate(r.model))
    }

    /// Non-translate sessions are untouched: Turbo stays Turbo (the swap is translate-
    /// only, so transcription quality/speed on Turbo is preserved).
    @Test func transcribeKeepsTurbo() {
        for kind in [CaptionEngineKind.appleTranscribe, .whisper, .whisperAppleTranslate] {
            #expect(
                WhisperKitEngine.effectiveModel(turbo, engineKind: kind, translate: false, locked: true) == turbo
            )
        }
    }

    /// Other models already audio-translate, so they're never swapped (no needless
    /// downgrade of Small/Medium/Tiny).
    @Test func translateCapableModelsAreNeverSwapped() {
        for model in ["tiny", "small", WhisperKitEngine.mediumModel] {
            for locked in [true, false] {
                let engine = CaptionEngineKind.select(
                    translate: true, localeSupported: false, authorized: false,
                    osHasApple: true, languageLocked: locked, translationInstalled: false
                )
                #expect(
                    WhisperKitEngine.effectiveModel(model, engineKind: engine, translate: true, locked: locked) == model
                )
            }
        }
    }

    /// Denylist honesty: anything added to the denylist routes to `.whisper` and so
    /// gets the swap, so re-adding a language can never resurrect the blank-English
    /// bug. The production set is empty, so assert it on a stand-in `.whisper` route.
    @Test func denylistedLanguageStillTranslatesOnTurbo() {
        // A denylisted locked language resolves to `.whisper` (audio-translate).
        let engine = CaptionEngineKind.whisper
        #expect(engine.needsAudioTranslate(translate: true, locked: true))
        #expect(
            WhisperKitEngine.effectiveModel(turbo, engineKind: engine, translate: true, locked: true)
                == WhisperKitEngine.mediumModel
        )
    }
}
