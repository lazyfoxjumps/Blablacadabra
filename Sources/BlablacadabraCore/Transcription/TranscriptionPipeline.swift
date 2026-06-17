import AVFoundation
import Foundation

/// What the caption UI consumes. `language` is the ISO 639-1 code of the
/// detected source language (nil when unknown), used to show the translation
/// direction. `original` is the source-language text shown above the
/// translation in bilingual mode (finals only; nil otherwise). `speaker` is the
/// per-session speaker label when speaker colors are on (nil = feature off, or
/// not yet labeled); finals carry it, partials inherit the previous line's.
public enum CaptionEvent: Sendable, Equatable {
    /// Rolling hypothesis for the utterance in progress; replaces the
    /// previous partial on screen.
    case partial(String, language: String? = nil, speaker: SpeakerID? = nil)
    /// The utterance is done; commit the line and start a fresh one.
    case final(String, original: String? = nil, language: String? = nil, speaker: SpeakerID? = nil)

    /// Returns a copy of this event with `speaker` attached. A nil argument
    /// leaves the event unchanged, so non-diarized events pass through cleanly.
    func withSpeaker(_ speaker: SpeakerID?) -> CaptionEvent {
        guard let speaker else { return self }
        switch self {
        case .partial(let text, let language, _):
            return .partial(text, language: language, speaker: speaker)
        case .final(let text, let original, let language, _):
            return .final(text, original: original, language: language, speaker: speaker)
        }
    }
}

/// Wires an `AudioSource` through VAD chunking into a `TranscriptionEngine`
/// and emits caption events: capture -> chunk -> transcribe -> caption.
///
/// Backpressure policy: transcription runs one chunk at a time. Finals queue
/// in order and are never dropped; partials only keep the newest (a stale
/// partial is worthless once a fresher one exists).
public actor TranscriptionPipeline: CaptionPipeline {
    private let source: AudioSource
    private let engine: TranscriptionEngine
    private let vadConfig: VADConfiguration

    /// Optional per-speaker labeler (Phase 6). When set, each FINAL utterance is
    /// run through it (concurrently with transcription, so it adds no latency)
    /// and the resulting `SpeakerID` rides on the final event. nil = speaker
    /// colors off; the pipeline behaves exactly as before.
    private let speakerIdentifier: SpeakerIdentifying?

    /// The translate toggle. Settable mid-stream; applies from the next chunk.
    public private(set) var task: TranscriptionTask

    /// The locked spoken language (ISO 639-1), or nil for auto-detect. When
    /// set, detection is skipped entirely: the code is forced on every decode.
    /// This is both the fix for misdetection (an English hum coming back as
    /// Japanese) and a latency win (one fewer model pass per final).
    public private(set) var spokenLanguage: String?

    /// Bilingual captions: when translating, also transcribe the original and
    /// surface it above the English. Settable mid-stream. Ignored unless
    /// `task == .translate`. Finals only (partials stay translation-only so
    /// the live latency the user feels stays low).
    public private(set) var showOriginal: Bool

    /// AUTO-detect feed for a `TranslatingPipeline` (Plan B). When true this
    /// pipeline is the INNER of a text-translating decorator on the unlocked
    /// translate path, and it does two extra things beyond plain transcription:
    ///   1. it DETECTS the source language even though the task is transcribe
    ///      (locked sessions skip this), tagging every event so the router knows
    ///      what to translate FROM, and
    ///   2. on each FINAL it also runs Whisper's own audio `.translate` pass and
    ///      carries that English in the event's `original` field as a per-line
    ///      FALLBACK. The decorator promotes the router's (Apple) translation when
    ///      the detected language is servable and uses this fallback otherwise, so a
    ///      language Apple can't translate still gets a caption instead of nothing.
    /// The extra audio-translate decode is the documented cost of robust auto-detect
    /// (Handoff item 6/7); it only applies to unlocked translate on macOS 26. The
    /// LOCKED path leaves this false and pays a single decode. nil for partials.
    private let autoTranslateSource: Bool

    /// Source-language stickiness gate (Plan B auto-detect). Re-detects on
    /// every final and only flips when the proposed language clears confidence
    /// + margin and survives a K-of-N streak. Originally cached the first
    /// detection forever, which pinned the router to the first foreign
    /// language and silently mistranslated every later one.
    private var languageGate = LanguageStickinessGate()

    /// Optional tap on incoming audio (converted pipeline-format samples);
    /// feeds level meters and debug dumps without touching the caption stream.
    private var audioTap: (@Sendable ([Float]) -> Void)?

    /// Linear input gain applied to every sample before VAD, the engine, and
    /// the tap. 1.0 = unchanged; >1 boosts soft voices so the VAD catches them
    /// and the meter shows them. Hard-clamped to [-1, 1] after scaling so a
    /// heavy boost distorts gently instead of wrapping. Settable mid-stream.
    /// Ignored while `autoGain` is on.
    private var inputGain: Float

    /// Hands-off auto-gain. When on, the pump drives the gain from the measured
    /// level via `autoGainController` and ignores the manual `inputGain`.
    private var autoGain: Bool = false
    private var autoGainController = AutoGainController()

    private var continuation: AsyncStream<CaptionEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var latestPartial: [Float]?
    private var finalQueue: [[Float]] = []
    private var transcribing = false
    private var sourceFinished = false
    private var engineReady = false

    public init(
        source: AudioSource,
        engine: TranscriptionEngine,
        task: TranscriptionTask = .transcribe,
        spokenLanguage: String? = nil,
        showOriginal: Bool = false,
        inputGain: Float = 1,
        speakerIdentifier: SpeakerIdentifying? = nil,
        autoTranslateSource: Bool = false,
        vadConfig: VADConfiguration = VADConfiguration()
    ) {
        self.source = source
        self.engine = engine
        self.task = task
        self.spokenLanguage = (spokenLanguage?.isEmpty == true) ? nil : spokenLanguage
        self.showOriginal = showOriginal
        self.inputGain = max(0.1, inputGain)
        self.speakerIdentifier = speakerIdentifier
        self.autoTranslateSource = autoTranslateSource
        self.vadConfig = vadConfig
    }

    public func setTask(_ newTask: TranscriptionTask) {
        task = newTask
        // A fresh task re-detects from scratch (and turning translate off
        // clears the "from" language the status line was showing).
        languageGate.reset()
    }

    /// Locks the spoken language (nil/empty = auto-detect). Applies mid-stream;
    /// clearing the cache so the new choice takes hold on the next chunk.
    public func setSpokenLanguage(_ code: String?) {
        spokenLanguage = (code?.isEmpty == true) ? nil : code
        languageGate.reset()
    }

    public func setShowOriginal(_ show: Bool) {
        showOriginal = show
    }

    public func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?) {
        audioTap = tap
    }

    /// Live input gain (1.0 = unchanged). Applies from the next buffer. Ignored
    /// while auto-gain is on.
    public func setInputGain(_ gain: Float) {
        inputGain = max(0.1, gain)
    }

    /// Live auto-gain toggle. Re-arms the controller each time it's turned on so
    /// it starts from unity rather than a stale gain from a previous session.
    public func setAutoGain(_ enabled: Bool) {
        if enabled, !autoGain { autoGainController = AutoGainController() }
        autoGain = enabled
    }

    /// Starts capture, loads the engine, and returns the caption stream.
    /// The stream finishes after `stop()` once queued finals have drained.
    ///
    /// Capture starts BEFORE the model loads, for two reasons: speech during
    /// the load is chunked and queued instead of missed, and starting an
    /// SCStream after CoreML/ANE model loading has produced all-zero audio
    /// in testing (order matters; see Handoff.md).
    public func start() async throws -> AsyncStream<CaptionEvent> {
        guard pumpTask == nil else { throw AudioCaptureError.alreadyRunning }

        let audio = try await source.start()

        let stream = AsyncStream<CaptionEvent> { continuation in
            self.continuation = continuation
        }

        pumpTask = Task {
            var chunker = VoiceChunker(config: vadConfig)
            for await buffer in audio {
                guard !Task.isCancelled else { break }
                var samples = Self.floatSamples(of: buffer)
                let gain: Float
                if autoGain {
                    // AGC drives the gain from the measured pre-gain level; it
                    // only adapts up on speech, so silence is never boosted into
                    // the VAD. Manual `inputGain` is ignored while it's on.
                    var sum: Float = 0
                    for sample in samples { sum += sample * sample }
                    let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
                    gain = autoGainController.update(rms: rms)
                } else {
                    gain = inputGain
                }
                if gain != 1 {
                    samples = samples.map { max(-1, min(1, $0 * gain)) }
                }
                audioTap?(samples)
                for event in chunker.process(samples) {
                    enqueue(event)
                }
            }
            if let last = chunker.flush() {
                enqueue(last)
            }
            sourceFinished = true
            finishIfDrained()
        }

        do {
            try await engine.prepare()
        } catch {
            await stop()
            throw error
        }
        engineReady = true
        pumpTranscriber() // drain anything chunked while the model loaded

        return stream
    }

    public func stop() async {
        await source.stop() // finishes the audio stream; pump loop then exits
        await pumpTask?.value
        pumpTask = nil
    }

    private func enqueue(_ event: VoiceChunker.Event) {
        switch event {
        case .partial(let samples):
            latestPartial = samples
        case .final(let samples):
            finalQueue.append(samples)
            latestPartial = nil // the final supersedes its own partials
        }
        pumpTranscriber()
    }

    private func pumpTranscriber() {
        guard engineReady, !transcribing else { return }

        let samples: [Float]
        let isFinal: Bool
        if !finalQueue.isEmpty {
            samples = finalQueue.removeFirst()
            isFinal = true
        } else if let partial = latestPartial {
            latestPartial = nil
            samples = partial
            isFinal = false
        } else {
            finishIfDrained()
            return
        }

        transcribing = true
        Task {
            if let event = await produceEvent(samples: samples, isFinal: isFinal) {
                continuation?.yield(event)
            }
            transcribing = false
            pumpTranscriber()
        }
    }

    /// Turns one chunk of audio into a caption event, orchestrating the
    /// translate / transcribe / language-detect passes per the current mode.
    /// Per-chunk failures are skipped (a `nil` event), never fatal: one bad
    /// decode shouldn't kill a live caption session.
    private func produceEvent(samples: [Float], isFinal: Bool) async -> CaptionEvent? {
        // One language decision for the whole chunk: a locked language wins and
        // skips detection; auto mode detects once and reuses (see below).
        let language = await resolvedLanguage(for: samples, isFinal: isFinal)

        // Auto-detect feed for a text-translating decorator (Plan B): emit the
        // SOURCE transcription tagged with the detected language, and on finals also
        // carry Whisper's audio-translate as a per-line fallback (see the property).
        if autoTranslateSource {
            return await produceAutoTranslateSource(samples: samples, language: language, isFinal: isFinal)
        }

        // Partials never carry a speaker (they inherit the previous line's on
        // screen), so there's nothing to run concurrently.
        guard isFinal else {
            return await producePartial(samples: samples, language: language)
        }

        // Final: diarize CONCURRENTLY with transcription. The embedding (~26ms
        // in the spike) finishes well inside Whisper's decode, so attaching the
        // speaker costs no extra latency, and captions never block on it: if it
        // somehow yields nil, the line just commits unlabeled.
        async let speaker = identifySpeaker(samples)
        let event = await produceFinal(samples: samples, language: language)
        return event?.withSpeaker(await speaker)
    }

    /// The rolling-partial path: translation-only while translating (keeps the
    /// live latency the user feels low), plain transcription otherwise.
    private func producePartial(samples: [Float], language: String?) async -> CaptionEvent? {
        guard task == .translate else {
            let out = (try? await engine.transcribe(samples, task: .transcribe, language: language)) ?? .empty
            guard !out.text.isEmpty else { return nil }
            return .partial(out.text, language: language ?? out.detectedLanguage)
        }
        let english = ((try? await engine.transcribe(samples, task: .translate, language: language)) ?? .empty).text
        return english.isEmpty ? nil : .partial(english, language: language)
    }

    /// The finalized-utterance path (no speaker yet; the caller attaches it).
    private func produceFinal(samples: [Float], language: String?) async -> CaptionEvent? {
        guard task == .translate else {
            // Plain transcription: a locked language is honored; otherwise
            // English is assumed (auto-detection is translate-only, see
            // resolvedLanguage).
            let out = (try? await engine.transcribe(samples, task: .transcribe, language: language)) ?? .empty
            guard !out.text.isEmpty else { return nil }
            return .final(out.text, original: nil, language: language ?? out.detectedLanguage)
        }

        // Force the resolved language on both passes. The translate task
        // otherwise reports the target ("en"), and the transcribe task would
        // come back in English instead of the original.
        let english = ((try? await engine.transcribe(samples, task: .translate, language: language)) ?? .empty).text
        guard !english.isEmpty else { return nil }

        var original: String?
        if showOriginal {
            let src = (try? await engine.transcribe(samples, task: .transcribe, language: language)) ?? .empty
            original = src.text.isEmpty ? nil : src.text
        }
        return .final(english, original: original, language: language)
    }

    /// The auto-detect-source path (Plan B inner). Emits the SOURCE-language text as
    /// the event payload, tagged with the detected language so the decorator's router
    /// knows what to translate FROM. On finals it ALSO runs Whisper's audio-translate
    /// and stows that English in `original` as the decorator's per-line fallback for
    /// languages Apple can't serve. `original` is plumbing here (the decorator never
    /// shows it directly; it rebuilds the bilingual original from the source text).
    private func produceAutoTranslateSource(samples: [Float], language: String?, isFinal: Bool) async -> CaptionEvent? {
        let src = (try? await engine.transcribe(samples, task: .transcribe, language: language)) ?? .empty
        guard !src.text.isEmpty else { return nil }
        let resolved = language ?? src.detectedLanguage

        guard isFinal else {
            return .partial(src.text, language: resolved)
        }

        // Diarize concurrently (the engine actor serializes the two decodes anyway,
        // so the embedding overlaps the transcription pass at no extra latency).
        async let speaker = identifySpeaker(samples)
        let englishFallback = ((try? await engine.transcribe(samples, task: .translate, language: language)) ?? .empty).text
        return .final(
            src.text,
            original: englishFallback.isEmpty ? nil : englishFallback,
            language: resolved,
            speaker: await speaker
        )
    }

    /// Labels a finalized utterance, or nil when speaker colors are off or the
    /// labeler has nothing for this chunk. Always fail-soft.
    private func identifySpeaker(_ samples: [Float]) async -> SpeakerID? {
        guard let speakerIdentifier else { return nil }
        return await speakerIdentifier.identify(samples: samples)
    }

    /// The language to decode this chunk as. A locked `spokenLanguage` wins and
    /// never spends a detection pass. Auto-detection only runs while
    /// TRANSLATING: in plain transcription, auto means English (nil), because
    /// detection on ambiguous audio ("dah dah dah", humming) misfires and a
    /// cached wrong guess then forces every later English utterance into that
    /// language. Anyone captioning non-English without translating locks the
    /// language explicitly. In translate-auto mode the gate re-detects on each
    /// FINAL but only flips when the new language clears a confidence + margin
    /// gate AND survives K-of-N consecutive agreements (the misfire stays
    /// rejected; a sustained real switch goes through). Partials never detect
    /// (a tiny rolling partial is the least reliable moment to language-ID, and
    /// the next final settles it anyway) and reuse the gate's current value.
    private func resolvedLanguage(for samples: [Float], isFinal: Bool) async -> String? {
        if let spokenLanguage { return spokenLanguage }
        // Auto-detect runs while translating OR when feeding a translating decorator
        // in auto mode (Plan B); plain transcription assumes English (see above).
        guard task == .translate || autoTranslateSource else { return nil }
        // Partials inherit the gate's current value without consuming a slot in
        // the K-of-N streak; only finals drive the gate.
        guard isFinal else { return languageGate.current }
        if let detection = (try? await engine.detectLanguageDetailed(samples)) ?? nil {
            return languageGate.observe(detection)
        }
        // Engine doesn't expose probabilities (test fakes, future backends):
        // fall back to single-shot adoption so behavior matches the legacy
        // cache. The gate's reset() still clears it on task/lock changes.
        if let cached = languageGate.current { return cached }
        let detected = (try? await engine.detectLanguage(samples)) ?? nil
        if let detected { return languageGate.adoptIfEmpty(detected) }
        return nil
    }

    private func finishIfDrained() {
        guard sourceFinished, !transcribing, finalQueue.isEmpty, latestPartial == nil else { return }
        continuation?.finish()
        continuation = nil
    }

    private static func floatSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
