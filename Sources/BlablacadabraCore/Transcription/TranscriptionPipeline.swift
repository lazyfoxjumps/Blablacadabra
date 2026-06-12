import AVFoundation
import Foundation

/// What the caption UI consumes. The optional `language` is the ISO 639-1
/// code of the detected source language (nil when unknown), used to show the
/// translation direction in the status line.
public enum CaptionEvent: Sendable, Equatable {
    /// Rolling hypothesis for the utterance in progress; replaces the
    /// previous partial on screen.
    case partial(String, language: String? = nil)
    /// The utterance is done; commit the line and start a fresh one.
    case final(String, language: String? = nil)
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
        vadConfig: VADConfiguration = VADConfiguration()
    ) {
        self.source = source
        self.engine = engine
        self.task = task
        self.vadConfig = vadConfig
    }

    public func setTask(_ newTask: TranscriptionTask) {
        task = newTask
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
            // Per-chunk failures are skipped, not fatal: one bad decode
            // shouldn't kill a live caption session.
            let output = (try? await engine.transcribe(samples, task: task)) ?? .empty
            if !output.text.isEmpty {
                let language = output.detectedLanguage
                continuation?.yield(
                    isFinal
                        ? .final(output.text, language: language)
                        : .partial(output.text, language: language)
                )
            }
            transcribing = false
            pumpTranscriber()
        }
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
