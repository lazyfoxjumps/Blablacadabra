import Foundation

/// Tunables for voice-activity chunking. Durations are in seconds; audio is
/// assumed to be pipeline format (16 kHz mono Float32).
public struct VADConfiguration: Sendable {
    /// Analysis frame length. RMS energy is measured per frame.
    public var frameDuration: Double = 0.03
    /// RMS at or above this counts as speech. System audio at normal volume
    /// lands well above; raise if music/noise triggers false utterances.
    public var energyThreshold: Float = 0.012
    /// This much continuous silence after speech finalizes the utterance.
    public var silenceToFinalize: Double = 0.6
    /// Force-finalize an utterance that runs longer than this (keeps latency
    /// bounded during continuous speech; well under Whisper's 30s window).
    public var maxUtteranceDuration: Double = 10.0
    /// While an utterance is open, emit a rolling partial this often.
    public var partialInterval: Double = 1.0
    /// Audio kept from just before speech onset so first syllables survive.
    public var preRollDuration: Double = 0.25
    /// Utterances with less speech than this are dropped as blips (clicks,
    /// notification pings).
    public var minSpeechDuration: Double = 0.3
    /// Trailing silence kept on a finalized utterance.
    public var trailingSilenceKept: Double = 0.2

    public init() {}
}

/// Energy-based voice-activity chunker. Feed it pipeline-format samples as
/// they arrive; it groups speech into utterances, emitting rolling partials
/// while someone is talking and a final chunk when they pause.
///
/// Pure and synchronous by design (no audio APIs, no clocks) so it can be
/// unit-tested with synthesized sample arrays.
public struct VoiceChunker {
    public enum Event: Equatable, Sendable {
        /// The utterance so far; re-transcribe and replace the live caption.
        case partial([Float])
        /// The utterance is done; transcribe once more and commit the line.
        case final([Float])
    }

    private let config: VADConfiguration
    private let frameSize: Int
    private let preRollFrames: Int
    private let silenceFramesToFinalize: Int
    private let maxUtteranceFrames: Int
    private let partialIntervalFrames: Int
    private let minSpeechFrames: Int
    private let trailingKeptSamples: Int

    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var speaking = false
    private var trailingSilenceFrames = 0
    private var framesSinceLastPartial = 0
    private var speechFramesInUtterance = 0

    public init(config: VADConfiguration = VADConfiguration()) {
        self.config = config
        let rate = AudioPipelineFormat.sampleRate
        frameSize = max(1, Int(config.frameDuration * rate))
        preRollFrames = max(0, Int(config.preRollDuration / config.frameDuration))
        silenceFramesToFinalize = max(1, Int(config.silenceToFinalize / config.frameDuration))
        maxUtteranceFrames = max(1, Int(config.maxUtteranceDuration / config.frameDuration))
        partialIntervalFrames = max(1, Int(config.partialInterval / config.frameDuration))
        minSpeechFrames = max(1, Int(config.minSpeechDuration / config.frameDuration))
        trailingKeptSamples = Int(config.trailingSilenceKept * rate)
    }

    /// Feeds new samples in; returns zero or more chunk events.
    public mutating func process(_ samples: [Float]) -> [Event] {
        pending.append(contentsOf: samples)
        var events: [Event] = []
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            if let event = processFrame(frame) {
                events.append(event)
            }
        }
        return events
    }

    /// Call when the audio source ends to flush a still-open utterance.
    public mutating func flush() -> Event? {
        defer { reset() }
        guard speaking, speechFramesInUtterance >= minSpeechFrames else { return nil }
        return .final(utterance)
    }

    private mutating func processFrame(_ frame: [Float]) -> Event? {
        let isSpeech = rms(frame) >= config.energyThreshold

        guard speaking else {
            if isSpeech {
                speaking = true
                utterance = preRoll + frame
                preRoll = []
                trailingSilenceFrames = 0
                framesSinceLastPartial = 0
                speechFramesInUtterance = 1
            } else {
                preRoll.append(contentsOf: frame)
                let maxPreRoll = preRollFrames * frameSize
                if preRoll.count > maxPreRoll {
                    preRoll.removeFirst(preRoll.count - maxPreRoll)
                }
            }
            return nil
        }

        utterance.append(contentsOf: frame)
        framesSinceLastPartial += 1
        if isSpeech {
            speechFramesInUtterance += 1
            trailingSilenceFrames = 0
        } else {
            trailingSilenceFrames += 1
        }

        let utteranceFrames = utterance.count / frameSize
        if trailingSilenceFrames >= silenceFramesToFinalize || utteranceFrames >= maxUtteranceFrames {
            return finalize()
        }
        if isSpeech, framesSinceLastPartial >= partialIntervalFrames {
            framesSinceLastPartial = 0
            return .partial(utterance)
        }
        return nil
    }

    private mutating func finalize() -> Event? {
        defer { reset() }
        guard speechFramesInUtterance >= minSpeechFrames else { return nil }
        let trailingSilenceSamples = trailingSilenceFrames * frameSize
        let trim = max(0, trailingSilenceSamples - trailingKeptSamples)
        let chunk = Array(utterance.dropLast(trim))
        return .final(chunk)
    }

    private mutating func reset() {
        utterance = []
        preRoll = []
        speaking = false
        trailingSilenceFrames = 0
        framesSinceLastPartial = 0
        speechFramesInUtterance = 0
    }

    private func rms(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame {
            sum += sample * sample
        }
        return (sum / Float(frame.count)).squareRoot()
    }
}
