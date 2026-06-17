import Foundation
import Testing
@testable import BlablacadabraCore

/// Covers the `TranslationRouter` decisions that DON'T touch the live `Translation`
/// framework: empty/unknown input, never translating into the target language, the
/// denylist `.whisper` policy short-circuit, and the policy-table derivation. The
/// install probe + real Apple translation are integration-only (gotcha 21), so the
/// `.auto`-with-installed-pack path is exercised live, not here.
///
/// The Swift Testing macros can't sit under `@available`, so each test guards
/// `#available(macOS 26, *)` and no-ops on older OSes (the router is macOS 26-only).
@Suite struct TranslationRouterTests {
    @Test func defaultPolicyMapsDenylistToWhisper() {
        guard #available(macOS 26, *) else { return }
        let table = TranslationRouter.defaultPolicy
        // Every denylisted source is steered to the Whisper fallback (the set is
        // currently empty, so this is vacuous; the .whisper mechanism is covered
        // by explicitWhisperPolicyOverridesAuto).
        for iso in CaptionEngineKind.appleTranslateDenylist {
            #expect(table[iso] == .whisper)
        }
        // A non-denylisted language has no override (defaults to .auto). id is no
        // longer denylisted, so it too defaults to .auto (Apple where installed).
        #expect(table["ja"] == nil)
        #expect(table["id"] == nil)
    }

    @Test func returnsNilForEmptyOrUnknownSource() async {
        guard #available(macOS 26, *) else { return }
        let router = TranslationRouter()
        #expect(await router.translate("", from: "ja") == nil)        // empty text
        #expect(await router.translate("hola", from: nil) == nil)      // language not yet detected
        #expect(await router.translate("hola", from: "") == nil)       // blank language
    }

    @Test func neverTranslatesIntoTheTargetLanguage() async {
        guard #available(macOS 26, *) else { return }
        let router = TranslationRouter(targetISOCode: "en")
        // English source -> English target is a no-op (no second decode, no Apple call).
        #expect(await router.translate("hello", from: "en") == nil)
    }

    @Test func denylistedLanguageReturnsNilWithoutTouchingApple() async {
        guard #available(macOS 26, *) else { return }
        // A policy `.whisper` language: the router returns nil so the caller uses the
        // Whisper fallback, and it does so WITHOUT probing the install state. The
        // production denylist is empty now, so this injects one to test the
        // short-circuit (id itself is no longer steered here).
        let router = TranslationRouter(policy: ["id": .whisper])
        #expect(await router.translate("apa kabar", from: "id") == nil)
    }

    @Test func explicitWhisperPolicyOverridesAuto() async {
        guard #available(macOS 26, *) else { return }
        // A caller can steer any language to the fallback via the policy table.
        let router = TranslationRouter(policy: ["ja": .whisper])
        #expect(await router.translate("こんにちは", from: "ja") == nil)
    }
}
