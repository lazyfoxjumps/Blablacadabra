import Foundation
import Translation

// Step 0 SDK spike for Round 2 (Apple Translation fast-path) — diagnostic pass.
// Earlier finding: status(from: id, to: en) == .installed, yet a direct
// TranslationSession(installedSource: id, target: en) threw .notInstalled on
// prepareTranslation(). This pass pins down the RELIABLE gate: which call
// actually tells us a pair is usable, and whether translate() works without
// prepareTranslation().
//
// GOTCHA: LanguageAvailability and TranslationSession are NON-Sendable with
// nonisolated async members — confine to one actor (Swift 5 mode tolerates it).

actor Probe {
    func run() async {
        print("=== Translation spike: id->en deep dive ===\n")

        let availability = LanguageAvailability()
        let en = Locale.Language(identifier: "en")
        let enUS = Locale.Language(identifier: "en-US")
        let id = Locale.Language(identifier: "id")

        print("status id->en    : \(await availability.status(from: id, to: en))")
        print("status id->en-US : \(await availability.status(from: id, to: enUS))")
        print("status id->nil   : \(await availability.status(from: id, to: nil))\n")

        // A) translate WITHOUT prepareTranslation, target en
        await attempt("A) id->en, translate only (no prepare)") {
            let s = TranslationSession(installedSource: id, target: en)
            return try await s.translate("Selamat pagi, nama saya Tanaka.").targetText
        }

        // B) prepareTranslation THEN translate, target en
        await attempt("B) id->en, prepare then translate") {
            let s = TranslationSession(installedSource: id, target: en)
            try await s.prepareTranslation()
            return try await s.translate("Selamat pagi, nama saya Tanaka.").targetText
        }

        // C) target nil (let the system pick the device language as target)
        await attempt("C) id->nil, translate only") {
            let s = TranslationSession(installedSource: id, target: nil)
            return try await s.translate("Selamat pagi, nama saya Tanaka.").targetText
        }

        // D) target en-US explicit
        await attempt("D) id->en-US, translate only") {
            let s = TranslationSession(installedSource: id, target: enUS)
            return try await s.translate("Selamat pagi, nama saya Tanaka.").targetText
        }

        print("\n=== spike done ===")
    }

    func attempt(_ label: String, _ body: () async throws -> String) async {
        print(label)
        do {
            let out = try await body()
            print("   OK -> \(out)\n")
        } catch let e as TranslationError {
            print("   TranslationError: \(e)\n")
        } catch {
            print("   error: \(error)\n")
        }
    }
}

@main
struct TranslationSpike {
    static func main() async { await Probe().run() }
}
