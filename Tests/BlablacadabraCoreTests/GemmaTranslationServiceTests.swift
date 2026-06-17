import Foundation
import Testing
@testable import BlablacadabraCore

/// Phase 7B (B.2) — contract tests for the Gemma translation backend.
///
/// These prove the actor honors the `TextTranslating` contract and plugs into the
/// SAME seam Apple's service uses, WITHOUT any weights, model, or hardware. The one
/// test that needs real weights is env-gated so CI skips (never fails) it. None of
/// this asserts translation QUALITY — that is the B.4 bake-off's job on real Macs.
@Suite struct GemmaTranslationServiceTests {

    // MARK: - start() failure paths (fall back before any audio is captured)

    @Test func startThrowsWhenWeightsMissing() async throws {
        // A localPath that doesn't exist on disk -> weightsUnavailable.
        let missing = URL(fileURLWithPath: "/tmp/blablacadabra-does-not-exist-\(UInt32.max)")
        let service = GemmaTranslationService(weights: .localPath(missing))
        await #expect(throws: GemmaTranslationError.weightsUnavailable) {
            try await service.start()
        }
    }

    @Test func startThrowsForAutoDownloadUntilB3() async throws {
        // Auto-download is wired to the not-yet-built B.3 weights store.
        let service = GemmaTranslationService(weights: .autoDownload)
        await #expect(throws: GemmaTranslationError.autoDownloadNotImplemented) {
            try await service.start()
        }
    }

    // MARK: - translate() contract (model-free)

    @Test func translateReturnsNilOnEmptyInput() async throws {
        let service = GemmaTranslationService(weights: .autoDownload)
        #expect(await service.translate("", from: "es") == nil)
        #expect(await service.translate("   \n ", from: "es") == nil)
    }

    @Test func translateReturnsNilOnUnservableSourceISO() async throws {
        // A non-nil source code we don't recognize is rejected before the model is
        // ever consulted — deterministic and matches AppleTranslationService.
        let service = GemmaTranslationService(weights: .autoDownload)
        #expect(await service.translate("hola mundo", from: "zz") == nil)
    }

    @Test func translateReturnsNilBeforeStart() async throws {
        // Servable source but never started: no model -> nil (line is skipped).
        let service = GemmaTranslationService(weights: .autoDownload)
        #expect(await service.translate("hola mundo", from: "es") == nil)
    }

    // MARK: - stop() idempotence

    @Test func stopIsIdempotent() async throws {
        let service = GemmaTranslationService(weights: .autoDownload)
        await service.stop()
        await service.stop()
        // Still safely returns nil after teardown.
        #expect(await service.translate("hola", from: "es") == nil)
    }

    // MARK: - Seam interchangeability (the Phase A promise)

    @Test func pluggsIntoTranslatingPipelineAsTextTranslating() async throws {
        // The decorator must accept GemmaTranslationService anywhere AppleTranslation
        // Service goes. With auto-download (no B.3 yet) the translator's start() throws,
        // so the pipeline refuses to open capture — exactly the missing-pack behavior.
        let inner = ScriptedPipelineForGemma([.final("hola")])
        let pipeline = TranslatingPipeline(
            inner: inner,
            translator: GemmaTranslationService(weights: .autoDownload),
            sourceISO: "es",
            showOriginal: false
        )
        await #expect(throws: GemmaTranslationError.self) {
            _ = try await pipeline.start()
        }
        #expect(await inner.didStart == false)
    }

    // MARK: - Real-weights smoke test (env-gated; skipped without a model)

    /// Set GEMMA_WEIGHTS_PATH to a folder holding config.json + tokenizer + *.safetensors
    /// to actually exercise the decoder. Skipped (not failed) when unset, so CI without
    /// the ~2.5GB model stays green. This only checks the line is NON-EMPTY; quality is
    /// scored by hand in the B.4 bake-off, never asserted here.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMMA_WEIGHTS_PATH"] != nil))
    func translateProducesNonEmptyForKnownPair() async throws {
        let path = ProcessInfo.processInfo.environment["GEMMA_WEIGHTS_PATH"]!
        let service = GemmaTranslationService(weights: .localPath(URL(fileURLWithPath: path)))
        try await service.start()
        let english = await service.translate("Hola, ¿cómo estás?", from: "es")
        await service.stop()
        #expect(english?.isEmpty == false)
    }
}

/// A minimal inner pipeline for the seam test (the TranslatingPipelineTests one is
/// private to that file). Plays a fixed script and records whether it started.
private actor ScriptedPipelineForGemma: CaptionPipeline {
    private let script: [CaptionEvent]
    private(set) var started = false

    init(_ script: [CaptionEvent]) { self.script = script }

    func start() async throws -> AsyncStream<CaptionEvent> {
        started = true
        let script = self.script
        return AsyncStream<CaptionEvent> { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }

    func stop() async {}
    func setTask(_ newTask: TranscriptionTask) {}
    func setSpokenLanguage(_ code: String?) {}
    func setShowOriginal(_ show: Bool) {}
    func setInputGain(_ gain: Float) {}
    func setAutoGain(_ enabled: Bool) {}
    func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?) {}

    var didStart: Bool { started }
}
