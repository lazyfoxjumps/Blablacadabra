import AVFoundation
import Foundation

/// What the caption UI consumes. `language` is the ISO 639-1 code of the
/// detected source language (nil when unknown), used to show the translation
/// direction. `original` is the source-language text shown above the
/// translation in bilingual mode (finals only; nil otherwise).
public enum CaptionEvent: Sendable, Equatable {
    /// Rolling hypothesis for the utterance in progress; replaces the
    /// previous partial on screen.
    case partial(String, language: String? = nil)
    /// The utterance is done; commit the line and start a fresh one.
    case final(String, original: String? = nil, language: String? = nil)
}

/// Wires an `AudioSource` through VAD chunking into a `TranscriptionEngine`
/// and emits caption events: capture -> chunk -> transcribe -> caption.
///
/// Backpressure policy: transcription runs one chunk at a time. Finals queue
/// in order and are never dropped; partials only keep the newest (a stale
/// partial is worthless once a fresher one exists).
public actor TranscriptionPipeline {
    private let source: AudioSource
    private let engine: TranscriptionEngine
    private let vadConfig: VADConfiguration

    /// The translate toggle. Settable mid-stream; applies from the next chunk.
    public private(set) var task: TranscriptionTask

    /// Bilingual captions: when translating, also transcribe the original and
    /// surface it above the English. Settable mid-stream. Ignored unless
    /// `task == .translate`. Finals only (partials stay translation-only so
    /// the live latency the user feels stays low).
    public private(set) var showOriginal: Bool

    /// Last detected source language, carried onto partials (which don't run
    /// their own detection) so the status line doesn't flicker between
    /// utterances.
    private var lastLanguage: String?

    /// Optional tap on incoming audio (converted pipeline-format samples);
    /// feeds level meters and debug dumps without touching the caption stream.
    private var audioTap: (@Sendable ([Float]) -> Void)?

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
        showOriginal: Bool = false,
        vadConfig: VADConfiguration = VADConfiguration()
    ) {
        self.source = source
        self.engine = engine
        self.task = task
        self.showOriginal = showOriginal
        self.vadConfig = vadConfig
    }

    public func setTask(_ newTask: TranscriptionTask) {
        task = newTask
        if newTask != .translate { lastLanguage = nil }
    }

    public func setShowOriginal(_ show: Bool) {
        showOriginal = show
    }

    public func setAudioTap(_ tap: (@Sendable ([Float]) -> Void)?) {
        audioTap = tap
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
                let samples = Self.floatSamples(of: buffer)
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
        guard task == .translate else {
            // Plain transcription: detect then transcribe in that language, so
            // a non-English speaker isn't forced into English text.
            let language = (try? await engine.detectLanguage(samples)) ?? nil
            let out = (try? await engine.transcribe(samples, task: .transcribe, language: language)) ?? .empty
            guard !out.text.isEmpty else { return nil }
            let reported = language ?? out.detectedLanguage
            return isFinal
                ? .final(out.text, original: nil, language: reported)
                : .partial(out.text, language: reported)
        }

        // Translating. Partials stay translation-only (keep the live latency
        // the user feels low) and reuse the last known source language.
        if !isFinal {
            let english = ((try? await engine.transcribe(samples, task: .translate, language: lastLanguage)) ?? .empty).text
            return english.isEmpty ? nil : .partial(english, language: lastLanguage)
        }

        // Final: detect the source once, then force it on both passes. The
        // translate task otherwise reports the target ("en"), and the
        // transcribe task would come back in English instead of the original.
        let source = (try? await engine.detectLanguage(samples)) ?? nil
        let english = ((try? await engine.transcribe(samples, task: .translate, language: source)) ?? .empty).text
        guard !english.isEmpty else { return nil }

        var original: String?
        if showOriginal {
            let src = (try? await engine.transcribe(samples, task: .transcribe, language: source)) ?? .empty
            original = src.text.isEmpty ? nil : src.text
        }
        if let source { lastLanguage = source }
        return .final(english, original: original, language: source ?? lastLanguage)
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
