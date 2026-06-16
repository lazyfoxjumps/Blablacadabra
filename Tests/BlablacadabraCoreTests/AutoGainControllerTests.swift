import Testing
@testable import BlablacadabraCore

// NOTE: same toolchain caveat as VoiceChunkerTests (needs the Testing module).

@Suite struct AutoGainControllerTests {
    @Test func quietSpeechIsBoostedTowardTarget() {
        var agc = AutoGainController()
        // A quiet talker at RMS 0.03; AGC should climb the gain over a few
        // buffers toward target/rms ≈ 0.12/0.03 = 4×.
        for _ in 0..<60 { agc.update(rms: 0.03) }
        #expect(agc.gain > 2.5)
        #expect(agc.gain <= 6.0)         // never past the ceiling
    }

    @Test func silenceIsNeverBoosted() {
        // The accessibility-critical guard: a quiet room (pure noise floor) must
        // NOT get cranked up, or the VAD sees amplified hiss and Whisper
        // hallucinates. Gain must stay at unity through sustained near-silence.
        var agc = AutoGainController()
        for _ in 0..<100 { agc.update(rms: 0.004) }   // below the speech gate
        #expect(agc.gain == 1.0)
    }

    @Test func loudSpeechIsNotAttenuatedBelowUnity() {
        var agc = AutoGainController()
        // Already-loud speech (0.3) would want a <1 gain to hit target, but the
        // floor is unity: we boost soft input, we don't duck loud input.
        for _ in 0..<60 { agc.update(rms: 0.3) }
        #expect(agc.gain == 1.0)
    }

    @Test func gainHoldsThroughSpeechPauses() {
        var agc = AutoGainController()
        for _ in 0..<60 { agc.update(rms: 0.03) }     // ramp up on speech
        let boosted = agc.gain
        for _ in 0..<30 { agc.update(rms: 0.0) }      // a pause
        #expect(agc.gain == boosted)                  // held, not reset
    }
}
