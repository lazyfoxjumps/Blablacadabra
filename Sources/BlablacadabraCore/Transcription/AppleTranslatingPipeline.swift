import AVFoundation
import Foundation

/// The Round 2 Apple translate fast-path: a `CaptionPipeline` that composes an
/// `AppleSpeechPipeline` (streaming `SpeechAnalyzer` transcription in the source
/// locale) with an `AppleTranslationService` (Apple `Translation` to English).
///
/// It's a DECORATOR, not a fork: the inner `AppleSpeechPipeline` does all the
/// capture / format-conversion / analyzer work and emits source-language
/// `CaptionEvent`s; this layer translates each into English and re-emits. So the
/// fast transcription path is shared with the transcribe-only mode, and bilingual
/// is near-free: the original line is already the transcriber's text (no second
/// transcription pass the way WhisperKit needs).
///
/// Translation is decoupled from transcription with the same backpressure policy
/// `TranscriptionPipeline` uses: one translation in flight at a time, finals
/// queued in order and never dropped, only the newest partial kept (a stale
/// partial is worthless once a fresher one exists). This keeps the live latency
/// the user feels low even if translation briefly lags a burst of speech.
///
/// Why the locale is fixed at init (no live `setTask`/`setSpokenLanguage`): Apple
/// needs a KNOWN source language for both transcription and translation, so
/// `AppState` only builds this when the user has locked a language, and a change
/// to the language or the translate toggle is handled by an `AppState` restart.
@available(macOS 26, *)
public actor AppleTranslatingPipeline: CaptionPipeline {
    private let inner: AppleSpeechPipeline
    private let translator: AppleTranslationService
    /// ISO 639-1 source code tagged on every emitted event so the status line can
    /// name the translation direction (e.g. "Indonesian → English").
    private let sourceISO: String?

    /// Bilingual: when on, finals carry the source-language text above the English.
    private var showOriginal: Bool

    private var continuation: AsyncStream<CaptionEvent>.Continuation?
    private var consumeTask: Task<Void, Never>?

    // Backpressure state (mirrors TranscriptionPipeline): newest partial only,
    // finals in order, one translation at a time. Each queued final carries the
    // speaker label the inner pipeline diarized, so it rides through translation
    // and onto the emitted English line (partials stay unlabeled, as elsewhere).
    private var pendingPartial: String?
    private var finalQueue: [(text: String, speaker: SpeakerID?)] = []
    private var translating = false
    private var innerFinished = false

    public init(
        source: AudioSource,
        locale: Locale,
        showOriginal: Bool,
        inputGain: Float = 1,
        speakerIdentifier: SpeakerIdentifying? = nil,
        installProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.inner = AppleSpeechPipeline(
            source: source,
            locale: locale,
            inputGain: inputGain,
            speakerIdentifier: speakerIdentifier,
            installProgress: installProgress
        )
        let iso = AppleSpeechLocale.isoCode(for: locale)
        self.sourceISO = iso
        self.translator = AppleTranslationService(sourceISOCode: iso ?? "en")
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
        case .partial(let text, _, _):
            pendingPartial = text
        case .final(let text, _, _, let speaker):
            finalQueue.append((text, speaker))
            pendingPartial = nil // the final supersedes its own partials
        }
        pump()
    }

    /// Translate the next pending item, finals first. One in flight at a time so
    /// finals stay ordered and a fresh partial never lands behind a stale one.
    private func pump() {
        guard !translating else { return }

        let text: String
        let isFinal: Bool
        let speaker: SpeakerID?
        if !finalQueue.isEmpty {
            let item = finalQueue.removeFirst()
            text = item.text
            speaker = item.speaker
            isFinal = true
        } else if let partial = pendingPartial {
            pendingPartial = nil
            text = partial
            speaker = nil
            isFinal = false
        } else {
            finishIfDrained()
            return
        }

        translating = true
        Task {
            let english = await translator.translate(text)
            if let english {
                if isFinal {
                    self.yieldCaption(.final(english, original: self.showOriginal ? text : nil, language: self.sourceISO, speaker: speaker))
                } else {
                    self.yieldCaption(.partial(english, language: self.sourceISO))
                }
            }
            // A nil translation (rare per-line failure) is skipped, not fatal.
            self.translating = false
            self.pump()
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
