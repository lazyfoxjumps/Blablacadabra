import Foundation

/// Hands-off input leveling (auto-gain / AGC). Measures the incoming (pre-gain)
/// RMS of each buffer and drives a gain toward a target speech level, so a quiet
/// mic gets normalized without the user ever riding the manual boost slider.
///
/// The one rule that matters for accessibility: it only adapts the gain UP while
/// there's ACTUAL speech, gated on the same `NoiseFloorFollower` the VAD uses. On
/// silence it HOLDS the gain instead of cranking it, so it never amplifies a
/// quiet room's noise floor up into the VAD — which is exactly the failure mode
/// that makes Whisper hallucinate captions onto silence. Boosting garbage louder
/// helps no one; a deaf user reading a hallucinated line is worse than reading a
/// slightly-quiet-but-true one.
///
/// Pure + synchronous (no audio APIs, no clocks): feed it a buffer's raw RMS, it
/// returns the gain to apply to that buffer. Easy to unit-test with RMS sequences.
public struct AutoGainController: Sendable {
    public struct Configuration: Sendable {
        /// Target RMS for speech after gain. Normal speech sits ~0.05-0.3; aim
        /// for the low-comfortable end so loud talkers don't slam into clipping.
        public var targetRMS: Float = 0.12
        /// Hard ceiling on applied gain.
        public var maxGain: Float = 6.0
        /// Floor on applied gain (1.0 = never attenuate below unity).
        public var minGain: Float = 1.0
        /// Per-buffer smoothing toward the desired gain while speech is present
        /// (0..1; smaller = slower, gentler, less audible pumping).
        public var attack: Float = 0.2
        /// Speech must exceed the tracked noise floor by this factor before it
        /// drives the gain. Mirrors the VAD's gate so AGC and VAD agree on what
        /// counts as voice.
        public var speechMargin: Float = 3.0
        /// Absolute minimum for the speech gate (matches the VAD's floor).
        public var absoluteFloor: Float = 0.012
        /// Ceiling for the noise-floor estimate (matches the VAD's ceiling).
        public var maxNoiseFloor: Float = 0.05
        /// Seconds for the noise-floor estimate to climb (matches the VAD).
        public var noiseFloorRiseTime: Double = 0.5

        public init() {}
    }

    private let config: Configuration
    private var floor: NoiseFloorFollower
    /// Current applied gain, smoothed across buffers.
    public private(set) var gain: Float

    /// - bufferDuration: nominal seconds per fed buffer (scales the floor's rise
    ///   rate). The pump feeds variable-size buffers; an approximate value is
    ///   fine since AGC is a slow control loop, not a sample-accurate process.
    public init(config: Configuration = .init(), bufferDuration: Double = 0.03) {
        self.config = config
        self.gain = config.minGain
        self.floor = NoiseFloorFollower(
            frameDuration: bufferDuration,
            riseTime: config.noiseFloorRiseTime,
            maxFloor: config.maxNoiseFloor
        )
    }

    /// Feed one buffer's pre-gain RMS; returns the gain to apply to that buffer.
    /// Adapts toward target only on speech; holds gain on silence.
    @discardableResult
    public mutating func update(rms: Float) -> Float {
        floor.update(rms)
        let threshold = floor.threshold(
            margin: config.speechMargin,
            absoluteMinimum: config.absoluteFloor
        )
        if rms >= threshold, rms > 0 {
            let desired = min(config.maxGain, max(config.minGain, config.targetRMS / rms))
            gain += (desired - gain) * config.attack
        }
        // Silence: hold the gain (do NOT boost the noise floor into the VAD).
        gain = min(config.maxGain, max(config.minGain, gain))
        return gain
    }
}
