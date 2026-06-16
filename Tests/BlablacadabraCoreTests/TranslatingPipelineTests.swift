import Foundation
import Testing
@testable import BlablacadabraCore

/// A fake `TextTranslating` backend: records inputs, returns a deterministic
/// "EN(<text>)" so order and content are checkable without the real Translation
/// framework. Can be made to fail on `start()` to exercise the warm-up fallback.
private actor FakeTranslator: TextTranslating {
    private let failOnStart: Bool
    private(set) var started = false
    private(set) var stopped = false
    private(set) var inputs: [String] = []

    init(failOnStart: Bool = false) { self.failOnStart = failOnStart }

    func start() async throws {
        if failOnStart { throw AppleSpeechUnavailable.translationUnavailable }
        started = true
    }

    func translate(_ text: String, from sourceISO: String?) async -> String? {
        inputs.append(text)
        return "EN(\(text))"
    }

    func stop() { stopped = true }

    var seenInputs: [String] { inputs }
    var didStart: Bool { started }
}

/// A fake router-style translator: serves only the languages in `servable`,
/// returning nil for anything else (so the decorator must use the inner's carried
/// fallback). Records the (text, from) pairs it was asked to translate.
private actor FakeRouter: TextTranslating {
    private let servable: Set<String>
    private(set) var inputs: [(text: String, from: String?)] = []

    init(servable: Set<String>) { self.servable = servable }

    func start() async throws {}
    func translate(_ text: String, from sourceISO: String?) async -> String? {
        inputs.append((text, sourceISO))
        guard let iso = sourceISO, servable.contains(iso) else { return nil }
        return "AR(\(text))"
    }
    func stop() {}

    var seenInputs: [(text: String, from: String?)] { inputs }
}

/// A fake inner `CaptionPipeline` that plays a fixed list of source-language events
/// into its stream and finishes, so the decorator's translation pump can be checked
/// without any audio or model.
private actor ScriptedPipeline: CaptionPipeline {
    private let script: [CaptionEvent]
    private(set) var started = false
    private(set) var stopped = false

    init(_ script: [CaptionEvent]) { self.script = script }

    func start() async throws -> AsyncStream<CaptionEvent> {
        started = true
        let script = self.script
        return AsyncStream<CaptionEvent> { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }

    func stop() async { stopped = true }
    func setTask(_ newTask: TranscriptionTask) {}
    func setSpokenLanguage(_ code: String?) {}
    func setShowOriginal(_ show: Bool) {}
    func setInputGain(_ gain: Float) {}
    func setAutoGain(_ enabled: Bool) {}
    func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?) {}

    var didStart: Bool { started }
}

@Suite struct TranslatingPipelineTests {
    /// Drains a started decorator's output stream to its natural end.
    private func collect(_ pipeline: TranslatingPipeline) async throws -> [CaptionEvent] {
        let stream = try await pipeline.start()
        var out: [CaptionEvent] = []
        for await event in stream { out.append(event) }
        return out
    }

    @Test func finalsTranslatedInOrderWithSpeakerPreserved() async throws {
        let inner = ScriptedPipeline([
            .final("salam", speaker: .speaker(1)),
            .final("kaif", speaker: .speaker(2)),
        ])
        let pipeline = TranslatingPipeline(
            inner: inner,
            translator: FakeTranslator(),
            sourceISO: "ar",
            showOriginal: false
        )

        let out = try await collect(pipeline)

        #expect(out == [
            .final("EN(salam)", original: nil, language: "ar", speaker: .speaker(1)),
            .final("EN(kaif)", original: nil, language: "ar", speaker: .speaker(2)),
        ])
    }

    @Test func bilingualKeepsSourceAsOriginal() async throws {
        let inner = ScriptedPipeline([.final("salam", speaker: .speaker(1))])
        let pipeline = TranslatingPipeline(
            inner: inner,
            translator: FakeTranslator(),
            sourceISO: "ar",
            showOriginal: true
        )

        let out = try await collect(pipeline)

        #expect(out == [
            .final("EN(salam)", original: "salam", language: "ar", speaker: .speaker(1)),
        ])
    }

    @Test func autoPathRoutesByPerLineDetectedLanguage() async throws {
        // The inner (auto mode) tags each final with the detected source language and
        // carries a Whisper audio-translate fallback in `original`. The decorator
        // routes by the per-line language: a servable one gets the router's output, an
        // unservable one falls back to the carried English. The emitted line is tagged
        // with the line's own language, not a fixed pipeline source.
        let inner = ScriptedPipeline([
            .final("salam", original: "WHISPER(salam)", language: "ar", speaker: .speaker(1)),
            .final("halo", original: "WHISPER(halo)", language: "id", speaker: .speaker(2)),
        ])
        let pipeline = TranslatingPipeline(
            inner: inner,
            translator: FakeRouter(servable: ["ar"]),
            sourceISO: nil,
            showOriginal: false
        )

        let out = try await collect(pipeline)

        #expect(out == [
            .final("AR(salam)", original: nil, language: "ar", speaker: .speaker(1)),
            .final("WHISPER(halo)", original: nil, language: "id", speaker: .speaker(2)),
        ])
    }

    @Test func autoPathSkipsLineWhenNeitherRouterNorFallbackHasText() async throws {
        // Unservable language AND no carried fallback (inner produced none) -> the line
        // is skipped, never blank-but-present.
        let inner = ScriptedPipeline([
            .final("halo", original: nil, language: "id", speaker: .speaker(1)),
        ])
        let pipeline = TranslatingPipeline(
            inner: inner,
            translator: FakeRouter(servable: ["ar"]),
            sourceISO: nil,
            showOriginal: false
        )

        let out = try await collect(pipeline)

        #expect(out.isEmpty)
    }

    @Test func startThrowsAndSkipsCaptureWhenTranslatorUnavailable() async throws {
        let inner = ScriptedPipeline([.final("salam")])
        let translator = FakeTranslator(failOnStart: true)
        let pipeline = TranslatingPipeline(
            inner: inner,
            translator: translator,
            sourceISO: "ar",
            showOriginal: false
        )

        await #expect(throws: AppleSpeechUnavailable.self) {
            _ = try await pipeline.start()
        }
        // The translator is warmed BEFORE the inner starts, so a bad pair means no
        // capture ever opened.
        #expect(await inner.didStart == false)
    }
}
