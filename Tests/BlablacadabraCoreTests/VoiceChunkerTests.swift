import Testing
@testable import BlablacadabraCore

// NOTE: cannot run under the Command Line Tools toolchain (no Testing module);
// see Handoff.md gotcha 6. Written against synthesized audio so they run the
// moment Xcode is updated.

private let rate = Int(AudioPipelineFormat.sampleRate)

/// Loud pseudo-speech: alternating-sign ramp with RMS ~0.2.
private func speech(seconds: Double) -> [Float] {
    let count = Int(seconds * Double(rate))
    return (0..<count).map { i in (i % 2 == 0 ? 0.2 : -0.2) }
}

private func silence(seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(rate)))
}

@Suite struct VoiceChunkerTests {
    @Test func speechThenPauseFinalizes() {
        var chunker = VoiceChunker()
        var events = chunker.process(speech(seconds: 0.5))
        events += chunker.process(silence(seconds: 1.0))

        let finals = events.filter { if case .final = $0 { return true } else { return false } }
        #expect(finals.count == 1)
        if case .final(let samples) = finals[0] {
            // Roughly the spoken 0.5s plus kept trailing silence; never the full 1.5s.
            #expect(samples.count > rate / 4)
            #expect(samples.count < rate)
        }
    }

    @Test func pureSilenceEmitsNothing() {
        var chunker = VoiceChunker()
        let events = chunker.process(silence(seconds: 3.0))
        #expect(events.isEmpty)
        #expect(chunker.flush() == nil)
    }

    @Test func shortBlipIsDropped() {
        var chunker = VoiceChunker()
        // 60ms click, well under minSpeechDuration.
        var events = chunker.process(speech(seconds: 0.06))
        events += chunker.process(silence(seconds: 1.0))
        #expect(events.isEmpty)
    }

    @Test func longSpeechEmitsRollingPartials() {
        var chunker = VoiceChunker()
        let events = chunker.process(speech(seconds: 3.5))
        let partials = events.filter { if case .partial = $0 { return true } else { return false } }
        // ~1 partial per second of continuous speech.
        #expect(partials.count >= 2)
    }

    @Test func maxUtteranceForcesFinal() {
        var config = VADConfiguration()
        config.maxUtteranceDuration = 2.0
        var chunker = VoiceChunker(config: config)
        let events = chunker.process(speech(seconds: 5.0))
        let finals = events.filter { if case .final = $0 { return true } else { return false } }
        #expect(finals.count >= 2)
    }

    @Test func forcedCutLandsOnQuietFrameAndKeepsRemainder() {
        var config = VADConfiguration()
        config.maxUtteranceDuration = 2.0
        config.forcedCutSearchWindow = 1.0
        var chunker = VoiceChunker(config: config)

        // 1.5s speech, a 90ms soft dip (under threshold, too short to
        // finalize), then speech to past the 2s wall and onward.
        var audio = speech(seconds: 1.5)
        audio += silence(seconds: 0.09)
        audio += speech(seconds: 1.5)
        var events = chunker.process(audio)

        let finals = events.compactMap { event -> [Float]? in
            if case .final(let samples) = event { return samples } else { return nil }
        }
        #expect(finals.count == 1)
        // The cut snaps to the dip (~1.55s in), not the 2s wall.
        if let chunk = finals.first {
            let seconds = Double(chunk.count) / Double(rate)
            #expect(seconds > 1.4)
            #expect(seconds < 1.8)
        }

        // The audio after the cut wasn't dropped: closing the utterance with
        // silence finalizes the carried remainder (~1.45s of speech).
        events = chunker.process(silence(seconds: 1.0))
        let tailFinals = events.compactMap { event -> [Float]? in
            if case .final(let samples) = event { return samples } else { return nil }
        }
        #expect(tailFinals.count == 1)
        if let tail = tailFinals.first {
            let seconds = Double(tail.count) / Double(rate)
            #expect(seconds > 1.0)
        }
    }

    @Test func flushFinalizesOpenUtterance() {
        var chunker = VoiceChunker()
        _ = chunker.process(speech(seconds: 0.5))
        let flushed = chunker.flush()
        #expect(flushed != nil)
        if case .final(let samples)? = flushed {
            #expect(samples.count >= rate / 4)
        }
    }

    @Test func preRollKeepsSpeechOnset() {
        var chunker = VoiceChunker()
        var events = chunker.process(silence(seconds: 1.0))
        events += chunker.process(speech(seconds: 0.5))
        events += chunker.process(silence(seconds: 1.0))
        let finals = events.compactMap { event -> [Float]? in
            if case .final(let samples) = event { return samples } else { return nil }
        }
        #expect(finals.count == 1)
        // Pre-roll means the chunk is a bit longer than the speech itself,
        // but it must not swallow the whole second of leading silence.
        if let chunk = finals.first {
            #expect(chunk.count > rate / 2)
            #expect(chunk.count < rate * 3 / 2)
        }
    }
}

@Suite struct WhisperNoiseFilterTests {
    @Test func emptyAndAnnotationsAreNoise() {
        #expect(WhisperKitEngine.isNoise(""))
        #expect(WhisperKitEngine.isNoise("[BLANK_AUDIO]"))
        #expect(WhisperKitEngine.isNoise("(music playing)"))
        #expect(WhisperKitEngine.isNoise("♪ ♪"))
    }

    @Test func realTextIsNotNoise() {
        #expect(!WhisperKitEngine.isNoise("Hello there."))
        #expect(!WhisperKitEngine.isNoise("It costs (roughly) ten dollars."))
    }

    @Test func leadingDialogDashIsStripped() {
        #expect(WhisperKitEngine.cleaned("- I'm going to pause.") == "I'm going to pause.")
        #expect(WhisperKitEngine.cleaned(" \u{2013} Right.") == "Right.")
        #expect(WhisperKitEngine.cleaned("Self-aware - mostly.") == "Self-aware - mostly.")
    }
}
