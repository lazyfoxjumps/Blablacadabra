import Foundation
import BlablacadabraCore

// MARK: - Phase 7B (B.4/B.5) — production translator factory
//
// The real factory the CLI uses: resolves weights through the B.3 `LLMWeightStore`
// (download-or-cache, off the live path), then builds the matching `TextTranslating`
// backend on the resolved `.localPath`. This is the wiring the scaffold reserved —
// `ensureAvailable` → `.localPath` — so each actor's `start()` never hits the network and
// the B.2 offline contract tests stay green. Both contenders are now real: Gemma (B.2) and
// MADLAD (B.5), so the bake-off is the two-horse race the plan locked.

public struct LLMTranslatorFactory: TranslatorFactory {
    private let targetLanguage: String
    private let store: LLMWeightStore
    private let onDownloadProgress: @Sendable (BakeOffModel, Double) -> Void

    public init(
        targetLanguage: String = "en",
        store: LLMWeightStore = LLMWeightStore(),
        onDownloadProgress: @escaping @Sendable (BakeOffModel, Double) -> Void = { _, _ in }
    ) {
        self.targetLanguage = targetLanguage
        self.store = store
        self.onDownloadProgress = onDownloadProgress
    }

    public func make(_ model: BakeOffModel) async throws -> any BakeOffTranslator {
        let progress = onDownloadProgress
        switch model {
        case .gemma3_4B, .gemma3_1B:
            let variant: GemmaTranslationService.ModelVariant = (model == .gemma3_4B) ? .gemma3_4B : .gemma3_1B
            let folder = try await store.ensureAvailable(variant) { progress(model, $0) }
            let service = GemmaTranslationService(
                targetLanguage: targetLanguage, modelVariant: variant, weights: .localPath(folder)
            )
            return GemmaBakeOffTranslator(service: service)

        case .madlad400_3B:
            let variant: MADLADTranslationService.ModelVariant = .madlad3B
            let folder = try await store.ensureAvailable(variant) { progress(model, $0) }
            let service = MADLADTranslationService(
                targetLanguage: targetLanguage, modelVariant: variant, weights: .localPath(folder)
            )
            return MADLADBakeOffTranslator(service: service)
        }
    }
}

/// Adapts `GemmaTranslationService` to the bake-off seam, surfacing the decoder's token count
/// (via the off-live-path `translateMeasured`) so tokens/sec is real, not estimated.
struct GemmaBakeOffTranslator: BakeOffTranslator {
    let service: GemmaTranslationService

    func warmUp() async throws { try await service.start() }

    func translate(_ line: String, sourceISO: String) async throws -> (text: String, outputTokens: Int) {
        // A skipped line (empty / unservable / runaway guardrail) is zero-token work, not a
        // hard failure, so one odd line doesn't void the whole clip.
        guard let result = await service.translateMeasured(line, from: sourceISO) else { return ("", 0) }
        return result
    }

    func tearDown() async { await service.stop() }
}

/// Adapts `MADLADTranslationService` to the bake-off seam (same contract as the Gemma adapter).
struct MADLADBakeOffTranslator: BakeOffTranslator {
    let service: MADLADTranslationService

    func warmUp() async throws { try await service.start() }

    func translate(_ line: String, sourceISO: String) async throws -> (text: String, outputTokens: Int) {
        guard let result = await service.translateMeasured(line, from: sourceISO) else { return ("", 0) }
        return result
    }

    func tearDown() async { await service.stop() }
}
