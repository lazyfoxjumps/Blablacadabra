import Foundation
import BlablacadabraCore

// MARK: - Phase 7B (B.4) — production translator factory
//
// The real factory the CLI uses: resolves weights through the B.3 `LLMWeightStore`
// (download-or-cache, off the live path), then builds a `GemmaTranslationService` on the
// resolved `.localPath`. This is exactly the wiring the scaffold reserved for B.4 —
// `ensureAvailable` → `.localPath` — so the actor's `start()` never hits the network and
// B.2's offline contract tests stay green. MADLAD has no backend yet, so it throws
// `unsupportedModel` and the runner turns that into an error row.

public struct GemmaTranslatorFactory: TranslatorFactory {
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
        let variant: GemmaTranslationService.ModelVariant
        switch model {
        case .gemma3_4B: variant = .gemma3_4B
        case .gemma3_1B: variant = .gemma3_1B
        case .madlad400_3B:
            throw BakeOffError.unsupportedModel(model.rawValue)
        }

        // Download-or-resolve to a local folder, then hand it to the B.2 actor unchanged.
        let progress = onDownloadProgress
        let folder = try await store.ensureAvailable(variant) { fraction in
            progress(model, fraction)
        }
        let service = GemmaTranslationService(
            targetLanguage: targetLanguage,
            modelVariant: variant,
            weights: .localPath(folder)
        )
        return GemmaBakeOffTranslator(service: service)
    }
}

/// Adapts `GemmaTranslationService` to the bake-off seam, surfacing the decoder's token
/// count (via the off-live-path `translateMeasured`) so tokens/sec is real, not estimated.
struct GemmaBakeOffTranslator: BakeOffTranslator {
    let service: GemmaTranslationService

    func warmUp() async throws {
        try await service.start()
    }

    func translate(_ line: String, sourceISO: String) async throws -> (text: String, outputTokens: Int) {
        // A skipped line (empty / unservable / runaway guardrail) counts as zero-token
        // work rather than a hard failure, so one odd line doesn't void the whole clip.
        guard let result = await service.translateMeasured(line, from: sourceISO) else {
            return ("", 0)
        }
        return result
    }

    func tearDown() async {
        await service.stop()
    }
}
