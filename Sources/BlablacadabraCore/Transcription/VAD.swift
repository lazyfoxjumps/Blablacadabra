import Foundation

/// Tunables for voice-activity chunking. Durations are in seconds; audio is
/// assumed to be pipeline format (16 kHz mono Float32).
public struct VADConfiguration: Sendable {
    /// Analysis frame length. RMS energy is measured per frame.
    public var frameDuration: Double = 0.03
    /// Absolute floor for the speech gate: the gate never drops below this, so a
    /// truly silent (digital-zero) source can't let numerical hiss register as
    /// speech. In a quiet room this dominates; once the background gets louder
    /// (a boosted mic, an amplified input) the adaptive noise floor takes over.
    /// See `noiseGateMargin`.
    public var energyThreshold: Float = 0.012
    /// Speech must exceed the tracked background-noise floor by this factor to
    /// OPEN an utterance. This is what stops a loud-but-steady hiss (e.g. after the
    /// input volume or boost is cranked up) from crossing `energyThreshold` and
    /// getting captioned as phantom speech. ~3× ≈ 9.5 dB above the floor; real
    /// speech onsets sit far higher. Paired with the lower `continuationGateMargin`
    /// below: the OPEN gate is strict (rejects hiss), the CONTINUATION gate is loose
    /// (keeps soft speech once we're sure it's speech). See `continuationGateMargin`.
    public var noiseGateMargin: Float = 3.0
    /// Once an utterance is OPEN, a frame only has to exceed the floor by THIS
    /// (smaller) factor to still count as speech rather than trailing silence.
    /// Hysteresis: a strict gate opens the utterance (no phantom captions on hiss),
    /// a looser gate holds it (quiet sentence tails and soft inter-word dips stay
    /// attached instead of being counted as silence and trimmed off). ~1.5× ≈ 3.5 dB
    /// above the floor: comfortably above steady hiss (which sits AT the floor), but
    /// low enough that a voice trailing off isn't clipped. Must be < `noiseGateMargin`
    /// for the hysteresis to exist; set equal to it to restore single-gate behavior.
    public var continuationGateMargin: Float = 1.5
    /// Seconds for the noise-floor estimate to climb toward a louder steady
    /// background (the EMA rise time). The estimate snaps DOWN instantly to a
    /// quieter level; it only climbs slowly, so a brief loud moment doesn't
    /// inflate it. Tuned so a freshly-boosted hiss is learned (and the gate
    /// closes on it) faster than `minSpeechDuration`, so steady noise never even
    /// accumulates a min-length utterance — not one phantom caption, not a burst.
    public var noiseFloorRiseTime: Double = 0.5
    /// Hard ceiling on the noise-floor estimate, so the gate can reject a loud
    /// hiss yet never climb up into real speech and start dropping it. Chosen so
    /// `maxNoiseFloor * noiseGateMargin` (≈0.15) stays comfortably below normal
    /// speech RMS (~0.1-0.3) while sitting above typical broadband hiss.
    public var maxNoiseFloor: Float = 0.05
    /// Absolute floor for the CONTINUATION gate (the in-utterance offset gate),
    /// mirroring `energyThreshold` for the open gate. Lower than `energyThreshold`
    /// so that in a genuinely quiet room (floor ≈ 0) a soft sentence tail still
    /// reads as speech and survives instead of being trimmed. Only ever consulted
    /// once an utterance is already open, so it can't let hiss start a phantom one.
    public var continuationEnergyThreshold: Float = 0.006
    /// Consecutive above-threshold frames required to OPEN an utterance. Keeps a
    /// lone click, notification ping, or single noisy frame from starting a
    /// phantom utterance. 1 = open on the first speech frame (old behavior).
    public var onsetSpeechFrames: Int = 2
    /// This much continuous silence after speech finalizes the utterance. Kept
    /// just under typical conversational turn-taking so a finalized line (and its
    /// translation) lands fast, without splitting a speaker who pauses mid-sentence.
    public var silenceToFinalize: Double = 0.45
    /// Force-finalize an utterance that runs longer than this (keeps latency
    /// bounded during continuous speech; well under Whisper's 30s window).
    public var maxUtteranceDuration: Double = 10.0
    /// While an utterance is open, emit a rolling partial this often.
    public var partialInterval: Double = 1.0
    /// Audio kept from just before speech onset so first syllables survive. Sized
    /// to cover a soft sentence opening that sits below the (strict) open gate for
    /// a beat before the voice rises enough to trigger it.
    public var preRollDuration: Double = 0.4
    /// Utterances with less speech than this are dropped as blips (clicks,
    /// notification pings).
    public var minSpeechDuration: Double = 0.3
    /// Trailing silence kept on a finalized utterance.
    public var trailingSilenceKept: Double = 0.35
    /// When an utterance hits `maxUtteranceDuration` mid-speech, the cut lands
    /// on the quietest frame within this much trailing audio (instead of dead
    /// at the limit, which chops words in half). The audio after the cut seeds
    /// the next utterance, so nothing is lost across the seam.
    public var forcedCutSearchWindow: Double = 2.0

    public init() {}
}

/// Tracks the steady background-noise RMS of a stream so callers can gate on
/// "speech is X above the floor" instead of a fixed absolute threshold (which
/// breaks the moment input gain pushes the noise floor up past it).
///
/// It's an asymmetric EMA: it snaps DOWN instantly when the room gets quieter,
/// and climbs UP only slowly (over `riseTime`) toward a louder steady
/// background. A hard `maxFloor` ceiling means it can rise enough to reject a
/// loud hiss but never climbs up into real-speech range and starts dropping
/// speech. Quiet dips between syllables keep it pinned near the true floor
/// during talking, so the estimate reflects the room, not the talker. Pure +
/// synchronous, so both the VAD and the auto-gain can reuse and unit-test it.
public struct NoiseFloorFollower: Sendable {
    /// Current background-noise RMS estimate.
    public private(set) var floor: Float
    private let riseCoef: Float
    private let maxFloor: Float

    /// - frameDuration: seconds per fed sample (scales the rise rate).
    /// - riseTime: seconds to climb (e-fold) toward a louder steady background.
    /// - maxFloor: hard ceiling, keeping the gate below real speech.
    /// - initialFloor: starting estimate (0 = learn from scratch; the absolute
    ///   gate stays in charge until the room is observed).
    public init(frameDuration: Double, riseTime: Double, maxFloor: Float, initialFloor: Float = 0) {
        self.floor = max(0, initialFloor)
        self.riseCoef = Float(min(1, frameDuration / max(frameDuration, riseTime)))
        self.maxFloor = maxFloor
    }

    /// Feed one frame's RMS; returns the updated floor. Snap down to a quieter
    /// level immediately; climb toward a louder one slowly; clamp to the ceiling.
    @discardableResult
    public mutating func update(_ rms: Float) -> Float {
        if rms < floor {
            floor = rms
        } else {
            floor += (rms - floor) * riseCoef
        }
        if floor > maxFloor { floor = maxFloor }
        return floor
    }

    /// The speech-gate threshold: `floor * margin`, never below `absoluteMinimum`.
    public func threshold(margin: Float, absoluteMinimum: Float) -> Float {
        max(absoluteMinimum, floor * margin)
    }
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
    private let forcedCutSearchFrames: Int

    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var speaking = false
    private var trailingSilenceFrames = 0
    private var framesSinceLastPartial = 0
    private var speechFramesInUtterance = 0
    /// Tracks the room's noise floor so the speech gate is relative to it, not a
    /// fixed number that a boosted mic floods straight through.
    private var noiseFloor: NoiseFloorFollower
    /// Consecutive above-gate frames seen while NOT yet in an utterance; an
    /// utterance opens only once this reaches `onsetSpeechFrames`.
    private var onsetFrames = 0

    public init(config: VADConfiguration = VADConfiguration()) {
        self.config = config
        let rate = AudioPipelineFormat.sampleRate
        noiseFloor = NoiseFloorFollower(
            frameDuration: config.frameDuration,
            riseTime: config.noiseFloorRiseTime,
            maxFloor: config.maxNoiseFloor
        )
        frameSize = max(1, Int(config.frameDuration * rate))
        preRollFrames = max(0, Int(config.preRollDuration / config.frameDuration))
        silenceFramesToFinalize = max(1, Int(config.silenceToFinalize / config.frameDuration))
        maxUtteranceFrames = max(1, Int(config.maxUtteranceDuration / config.frameDuration))
        partialIntervalFrames = max(1, Int(config.partialInterval / config.frameDuration))
        minSpeechFrames = max(1, Int(config.minSpeechDuration / config.frameDuration))
        trailingKeptSamples = Int(config.trailingSilenceKept * rate)
        forcedCutSearchFrames = max(1, Int(config.forcedCutSearchWindow / config.frameDuration))
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
        let energy = rms(frame)
        noiseFloor.update(energy)
        // Hysteresis: a strict OPEN gate starts an utterance (rejecting steady
        // hiss), a looser CONTINUATION gate decides speech-vs-silence once one is
        // already running (so a soft tail or inter-word dip stays attached instead
        // of being trimmed). See VADConfiguration for the rationale.
        let isOnset = energy >= noiseFloor.threshold(
            margin: config.noiseGateMargin,
            absoluteMinimum: config.energyThreshold
        )
        let isSpeech = energy >= noiseFloor.threshold(
            margin: config.continuationGateMargin,
            absoluteMinimum: config.continuationEnergyThreshold
        )

        guard speaking else {
            // Keep a rolling pre-roll of recent audio so the first syllables
            // survive once we commit to an utterance.
            preRoll.append(contentsOf: frame)
            let maxPreRoll = preRollFrames * frameSize
            if preRoll.count > maxPreRoll {
                preRoll.removeFirst(preRoll.count - maxPreRoll)
            }
            if isOnset {
                onsetFrames += 1
                // Open only after a few consecutive speech frames, so a lone
                // click/ping or single noisy frame can't start a phantom
                // utterance. The pre-roll already holds these onset frames.
                if onsetFrames >= max(1, config.onsetSpeechFrames) {
                    speaking = true
                    utterance = preRoll
                    preRoll = []
                    trailingSilenceFrames = 0
                    framesSinceLastPartial = 0
                    speechFramesInUtterance = onsetFrames
                    onsetFrames = 0
                }
            } else {
                onsetFrames = 0
            }
            return nil
        }

        utterance.append(contentsOf: frame)
        framesSinceLastPartial += 1
        // The min-length / blip-drop counter keys off the STRICT open gate, so a
        // transient (e.g. the noise floor still ramping up to a freshly-boosted
        // hiss) can't pad itself to a real utterance's length via the loose gate.
        if isOnset { speechFramesInUtterance += 1 }
        // Trailing silence (which drives finalize + trim) keys off the LOOSE
        // continuation gate, so a soft sentence tail keeps the utterance alive and
        // is kept rather than counted as silence and trimmed.
        if isSpeech { trailingSilenceFrames = 0 } else { trailingSilenceFrames += 1 }

        let utteranceFrames = utterance.count / frameSize
        if trailingSilenceFrames >= silenceFramesToFinalize {
            return finalize()
        }
        if utteranceFrames >= maxUtteranceFrames {
            return forcedFinalize()
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

    /// The utterance ran into the max-duration wall mid-speech. Cutting dead
    /// at the limit halves a word, and Whisper garbles half-words on both
    /// sides of the seam. Instead: cut on the quietest frame in the trailing
    /// search window and keep everything after the cut as the start of the
    /// next utterance.
    private mutating func forcedFinalize() -> Event? {
        guard speechFramesInUtterance >= minSpeechFrames else {
            reset()
            return nil
        }

        let totalFrames = utterance.count / frameSize
        let searchFrames = min(forcedCutSearchFrames, totalFrames - 1)
        var quietestFrame = totalFrames - 1
        var quietestRMS = Float.greatestFiniteMagnitude
        for index in (totalFrames - searchFrames)..<totalFrames {
            let start = index * frameSize
            let frame = Array(utterance[start..<(start + frameSize)])
            let energy = rms(frame)
            if energy < quietestRMS {
                quietestRMS = energy
                quietestFrame = index
            }
        }

        let cut = (quietestFrame + 1) * frameSize
        let chunk = Array(utterance.prefix(cut))
        let remainder = Array(utterance.suffix(from: min(cut, utterance.count)))

        // Stay in speaking state, seeded with the remainder; recount its
        // speech/silence frames so finalize bookkeeping starts honest. The
        // utterance is already open, so the remainder uses the CONTINUATION gate
        // (a snapshot is fine: these frames were already fed through the follower
        // on the way in).
        utterance = remainder
        speaking = true
        framesSinceLastPartial = 0
        speechFramesInUtterance = 0
        trailingSilenceFrames = 0
        let remainderOnsetThreshold = noiseFloor.threshold(
            margin: config.noiseGateMargin,
            absoluteMinimum: config.energyThreshold
        )
        let remainderSpeechThreshold = noiseFloor.threshold(
            margin: config.continuationGateMargin,
            absoluteMinimum: config.continuationEnergyThreshold
        )
        let remainderFrames = remainder.count / frameSize
        for index in 0..<remainderFrames {
            let start = index * frameSize
            let energy = rms(Array(remainder[start..<(start + frameSize)]))
            if energy >= remainderOnsetThreshold { speechFramesInUtterance += 1 }
            if energy >= remainderSpeechThreshold { trailingSilenceFrames = 0 } else { trailingSilenceFrames += 1 }
        }

        return .final(chunk)
    }

    private mutating func reset() {
        utterance = []
        preRoll = []
        speaking = false
        trailingSilenceFrames = 0
        framesSinceLastPartial = 0
        speechFramesInUtterance = 0
        onsetFrames = 0
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
