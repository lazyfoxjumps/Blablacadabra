import Foundation
import Testing
@testable import BlablacadabraCore

/// Phase 7B (B.5) — contract tests for the MADLAD translation backend.
///
/// Like the Gemma suite, these prove the actor honors the `TextTranslating` contract and
/// drops into the SAME seam, WITHOUT any weights, model, or hardware. The one real-weights
/// test is env-gated so CI skips (never fails) it. None of this asserts translation QUALITY
/// — that is the B.4 bake-off's job on real Macs.
@Suite struct MADLADTranslationServiceTests {

    // MARK: - start() failure paths (fall back before any audio is captured)

    @Test func startThrowsWhenWeightsMissing() async throws {
        let missing = URL(fileURLWithPath: "/tmp/madlad-does-not-exist-\(UInt32.max)")
        let service = MADLADTranslationService(weights: .localPath(missing))
        await #expect(throws: MADLADTranslationError.weightsUnavailable) {
            try await service.start()
        }
    }

    @Test func startThrowsForAutoDownloadUntilPhaseC() async throws {
        let service = MADLADTranslationService(weights: .autoDownload)
        await #expect(throws: MADLADTranslationError.autoDownloadNotImplemented) {
            try await service.start()
        }
    }

    // MARK: - translate() contract (model-free)

    @Test func translateReturnsNilOnEmptyInput() async throws {
        let service = MADLADTranslationService(weights: .autoDownload)
        #expect(await service.translate("", from: "es") == nil)
        #expect(await service.translate("   \n ", from: "es") == nil)
    }

    @Test func translateReturnsNilOnUnservableSourceISO() async throws {
        let service = MADLADTranslationService(weights: .autoDownload)
        #expect(await service.translate("hola mundo", from: "zz") == nil)
    }

    @Test func translateReturnsNilBeforeStart() async throws {
        let service = MADLADTranslationService(weights: .autoDownload)
        #expect(await service.translate("hola mundo", from: "es") == nil)
    }

    @Test func measuredVariantAlsoNilBeforeStart() async throws {
        let service = MADLADTranslationService(weights: .autoDownload)
        #expect(await service.translateMeasured("hola", from: "es") == nil)
    }

    // MARK: - stop() idempotence

    @Test func stopIsIdempotent() async throws {
        let service = MADLADTranslationService(weights: .autoDownload)
        await service.stop()
        await service.stop()
        #expect(await service.translate("hola", from: "es") == nil)
    }

    // MARK: - Seam interchangeability (the Phase A promise)

    @Test func conformsToTextTranslating() {
        // Compile-time proof it slots wherever AppleTranslationService / GemmaTranslationService
        // go: the pipeline takes `any TextTranslating`.
        let service: any TextTranslating = MADLADTranslationService(weights: .autoDownload)
        _ = service
    }

    // MARK: - Real-weights smoke test (env-gated; skipped without a model)

    /// Set MADLAD_WEIGHTS_PATH to a folder holding config.json + tokenizer + *.safetensors to
    /// exercise the encoder-decoder. Skipped (not failed) when unset. Checks the line is
    /// NON-EMPTY only; quality is scored by hand in the bake-off, never asserted here.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MADLAD_WEIGHTS_PATH"] != nil))
    func translateProducesNonEmptyForKnownPair() async throws {
        let path = ProcessInfo.processInfo.environment["MADLAD_WEIGHTS_PATH"]!
        let service = MADLADTranslationService(weights: .localPath(URL(fileURLWithPath: path)))
        try await service.start()
        let english = await service.translate("Hola, ¿cómo estás?", from: "es")
        await service.stop()
        #expect(english?.isEmpty == false)
    }
}
