import Foundation

/// A `CaptionPipeline` decorator that text-translates another pipeline's output to
/// English, line by line. The `inner` pipeline does all the capture / transcription
/// work and emits SOURCE-language `CaptionEvent`s; this layer runs each through a
/// `TextTranslating` backend and re-emits the English (with the source kept above
/// it in bilingual mode).
///
/// It's a DECORATOR, not a fork, and it's engine-agnostic: the inner can be the
/// Apple `SpeechAnalyzer` transcriber OR a WhisperKit `TranscriptionPipeline` in
/// transcribe mode. That decoupling is the fix for the old translate path, where
/// Whisper's audio `.translate` task produced garbage English on dialectal /
/// low-resource languages: now Whisper does the (reliable) transcription and a
/// dedicated text translator does the translation. Bilingual is near-free here: the
/// source line is already the inner transcriber's output, no second decode the way
/// WhisperKit's own audio-translate path needed.
///
/// Translation is decoupled from transcription with the same backpressure policy
/// `TranscriptionPipeline` uses: one translation in flight at a time, finals queued
/// in order and never dropped, only the newest partial kept (a stale partial is
/// worthless once a fresher one exists). The live latency the user feels stays low
/// even if translation briefly lags a burst of speech.
///
/// Why the source language is fixed for the life of the pipeline (no live
/// `setTask`/`setSpokenLanguage`): the translator needs a KNOWN source, so
/// `AppState` only builds this when the user has locked a language, and a change to
/// the language or the translate toggle is handled by an `AppState` restart.
public actor TranslatingPipeline: CaptionPipeline {
    private let inner: any CaptionPipeline
    private let translator: any TextTranslating
    /// Fallback ISO 639-1 source code, used to tag/route a line only when the inner
    /// event carries no language of its own. On the LOCKED path it's the locked
    /// language (every line is that language); on the AUTO path it's nil and the
    /// per-event detected language drives both routing and the status line.
    private let sourceISO: String?

    /// Bilingual: when on, finals carry the source-language text above the English.
    private var showOriginal: Bool

    private var continuation: AsyncStream<CaptionEvent>.Continuation?
    private var consumeTask: Task<Void, Never>?

    // Backpressure state (mirrors TranscriptionPipeline): newest partial only,
    // finals in order, one translation at a time. Each queued final carries the
    // inner pipeline's per-line metadata: the detected source `language` (routes the
    // translation and tags the emitted line), an `english` fallback (Whisper's own
    // audio-translate, used when the router can't serve the language; nil on the
    // locked path), and the diarized `speaker` (rides through onto the English line;
    // partials stay unlabeled, as elsewhere).
    private var pendingPartial: (text: String, language: String?)?
    private var finalQueue: [(source: String, fallback: String?, language: String?, speaker: SpeakerID?)] = []
    private var translating = false
    private var innerFinished = false

    public init(
        inner: any CaptionPipeline,
        translator: any TextTranslating,
        sourceISO: String?,
        showOriginal: Bool
    ) {
        self.inner = inner
        self.translator = translator
        self.sourceISO = sourceISO
        self.showOriginal = showOriginal
    }

    // MARK: - CaptionPipeline

    public func start() async throws -> AsyncStream<CaptionEvent> {
        guard consumeTask == nil else { throw AudioCaptureError.alreadyRunning }

        // Warm the translator FIRST: if this pair isn't usable, throw before any
        // audio is captured so `AppState` falls back to WhisperKit cleanly.
        try await translator.start()

        let innerStream = try await inner.start()

        let stream = AsyncStream<CaptionEvent> { continuation in
            self.continuation = continuation
        }

        // Consume the inner (source-language) events, translate, re-emit. When the
        // inner stream ends (capture stopped / source died), drain and finish.
        consumeTask = Task {
            for await event in innerStream {
                self.ingest(event)
            }
            self.innerFinished = true
            self.finishIfDrained()
        }

        return stream
    }

    public func stop() async {
        await inner.stop()        // finishes innerStream; the consume loop then exits
        await consumeTask?.value
        consumeTask = nil
        await translator.stop()
        finishCaptions()
    }

    /// No-op: translate-only path. Flipping translate off re-picks the engine via
    /// an `AppState` restart.
    public func setTask(_ newTask: TranscriptionTask) {}

    /// No-op: source locale is fixed at init; a language change restarts the
    /// session from `AppState`.
    public func setSpokenLanguage(_ code: String?) {}

    /// Bilingual toggle, applied live to subsequent finals.
    public func setShowOriginal(_ show: Bool) { showOriginal = show }

    /// Forwarded to the inner transcription pipeline. Fire-and-forget (gain isn't
    /// ordering-critical) so this satisfies the synchronous protocol requirement
    /// while crossing into the inner actor.
    public func setInputGain(_ gain: Float) {
        Task { await inner.setInputGain(gain) }
    }

    /// Forwarded to the inner pipeline (which owns the real audio path feeding the
    /// level meter). Fire-and-forget for the same reason as `setInputGain`.
    public func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?) {
        Task { await inner.setAudioTap(tap) }
    }

    // MARK: - Translation pump

    private func ingest(_ event: CaptionEvent) {
        switch event {
        case .partial(let text, let language, _):
            pendingPartial = (text, language)
        case .final(let text, let original, let language, let speaker):
            // On the auto path `original` is the inner's carried Whisper-translate
            // fallback; on the locked path it's nil. Either way the decorator rebuilds
            // the bilingual original from the SOURCE text it just routed.
            finalQueue.append((source: text, fallback: original, language: language, speaker: speaker))
            pendingPartial = nil // the final supersedes its own partials
        }
        pump()
    }

    /// Translate the next pending item, finals first. One in flight at a time so
    /// finals stay ordered and a fresh partial never lands behind a stale one.
    private func pump() {
        guard !translating else { return }

        if let item = finalQueue.first {
            finalQueue.removeFirst()
            let from = item.language ?? sourceISO
            translating = true
            Task {
                // Apple (via the router/service) is preferred; on a miss the line uses
                // the inner's carried Whisper-translate fallback so it never goes blank.
                let english = (await self.translator.translate(item.source, from: from)) ?? item.fallback
                if let english {
                    self.yieldCaption(.final(english, original: self.showOriginal ? item.source : nil, language: from, speaker: item.speaker))
                }
                self.translating = false
                self.pump()
            }
        } else if let partial = pendingPartial {
            pendingPartial = nil
            let from = partial.language ?? sourceISO
            translating = true
            Task {
                // Partials have no fallback (kept cheap); a miss just shows nothing
                // until the final settles it.
                let english = await self.translator.translate(partial.text, from: from)
                if let english {
                    self.yieldCaption(.partial(english, language: from))
                }
                self.translating = false
                self.pump()
            }
        } else {
            finishIfDrained()
        }
    }

    private func yieldCaption(_ event: CaptionEvent) {
        continuation?.yield(event)
    }

    private func finishIfDrained() {
        guard innerFinished, !translating, finalQueue.isEmpty, pendingPartial == nil else { return }
        finishCaptions()
    }

    private func finishCaptions() {
        continuation?.finish()
        continuation = nil
    }
}
