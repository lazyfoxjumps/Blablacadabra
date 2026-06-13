import AVFoundation
import Testing
@testable import BlablacadabraCore

@Suite struct SpeakerClustererTests {
    /// Builds a unit vector pointing along axis `i` in `dim` dimensions, so two
    /// different axes are orthogonal (cosine 0) and the same axis is identical
    /// (cosine 1). Handy for forcing "same speaker" vs "new speaker".
    private func axis(_ i: Int, dim: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[i] = 1
        return v
    }

    @Test func sameEmbeddingGetsSameSpeaker() {
        var c = SpeakerClusterer(maxSpeakers: 4, threshold: 0.65)
        #expect(c.assign(axis(0)) == .speaker(1))
        #expect(c.assign(axis(0)) == .speaker(1)) // identical -> same id
        #expect(c.speakerCount == 1)
    }

    @Test func farEmbeddingGetsNewSpeaker() {
        var c = SpeakerClusterer(maxSpeakers: 4, threshold: 0.65)
        #expect(c.assign(axis(0)) == .speaker(1))
        #expect(c.assign(axis(1)) == .speaker(2)) // orthogonal -> new id
        #expect(c.assign(axis(2)) == .speaker(3))
        #expect(c.speakerCount == 3)
    }

    @Test func nearbyEmbeddingStaysSameSpeaker() {
        var c = SpeakerClusterer(maxSpeakers: 4, threshold: 0.65)
        #expect(c.assign(axis(0)) == .speaker(1))
        // Mostly axis 0 with a little axis 1: cosine ~0.95 > threshold.
        #expect(c.assign([0.95, 0.31, 0, 0, 0, 0, 0, 0]) == .speaker(1))
        #expect(c.speakerCount == 1)
    }

    @Test func overflowBeyondCapMapsToOther() {
        var c = SpeakerClusterer(maxSpeakers: 2, threshold: 0.65)
        #expect(c.assign(axis(0)) == .speaker(1))
        #expect(c.assign(axis(1)) == .speaker(2))
        #expect(c.assign(axis(2)) == .other) // cap full
        #expect(c.assign(axis(3)) == .other)
        // A voice already known still resolves, even once overflowing.
        #expect(c.assign(axis(0)) == .speaker(1))
        #expect(c.speakerCount == 2)
    }

    @Test func resetClearsClusters() {
        var c = SpeakerClusterer(maxSpeakers: 4, threshold: 0.65)
        _ = c.assign(axis(0))
        _ = c.assign(axis(1))
        #expect(c.speakerCount == 2)
        c.reset()
        #expect(c.speakerCount == 0)
        // Numbering restarts at 1 after a reset.
        #expect(c.assign(axis(1)) == .speaker(1))
    }

    @Test func emptyEmbeddingIsOther() {
        var c = SpeakerClusterer()
        #expect(c.assign([]) == .other)
        #expect(c.speakerCount == 0)
    }
}

@Suite struct CaptionEventSpeakerTests {
    @Test func withSpeakerAttachesToFinal() {
        let base = CaptionEvent.final("hi", original: "salut", language: "fr")
        #expect(base.withSpeaker(.speaker(2)) == .final("hi", original: "salut", language: "fr", speaker: .speaker(2)))
    }

    @Test func withSpeakerAttachesToPartial() {
        let base = CaptionEvent.partial("hi", language: "fr")
        #expect(base.withSpeaker(.other) == .partial("hi", language: "fr", speaker: .other))
    }

    @Test func withNilSpeakerLeavesEventUnchanged() {
        let base = CaptionEvent.final("hi", language: "en")
        #expect(base.withSpeaker(nil) == base)
    }
}

@Suite struct DiarizationPipelineTests {
    /// Always returns the same canned label, so a test can assert the pipeline
    /// attaches it to finals (and not to partials) without the real model.
    private struct FixedIdentifier: SpeakerIdentifying {
        let id: SpeakerID
        func identify(samples: [Float]) async -> SpeakerID? { id }
        func reset() async {}
    }

    /// Minimal transcribe-only engine: every chunk comes back as the same line.
    private actor StubEngine: TranscriptionEngine {
        func prepare() async throws {}
        func transcribe(_ samples: [Float], task: TranscriptionTask, language: String?) async throws -> TranscriptionOutput {
            TranscriptionOutput(text: "hello", detectedLanguage: "en")
        }
        func detectLanguage(_ samples: [Float]) async throws -> String? { nil }
    }

    /// One second of speech-like audio, then ends; flush yields a single final.
    private actor OneShotSource: AudioSource {
        func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
            AsyncStream { continuation in
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: AudioPipelineFormat.sampleRate,
                    channels: 1,
                    interleaved: false
                )!
                let frames = AVAudioFrameCount(AudioPipelineFormat.sampleRate)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
                buffer.frameLength = frames
                let ptr = buffer.floatChannelData![0]
                for i in 0..<Int(frames) { ptr[i] = i % 2 == 0 ? 0.2 : -0.2 }
                continuation.yield(buffer)
                continuation.finish()
            }
        }
        func stop() async {}
    }

    @Test func finalCarriesSpeakerWhenIdentifierSet() async throws {
        let pipeline = TranscriptionPipeline(
            source: OneShotSource(),
            engine: StubEngine(),
            speakerIdentifier: FixedIdentifier(id: .speaker(1))
        )
        let stream = try await pipeline.start()
        var sawLabeledFinal = false
        for await event in stream {
            switch event {
            case .final(_, _, _, let speaker):
                #expect(speaker == .speaker(1))
                sawLabeledFinal = true
            case .partial(_, _, let speaker):
                #expect(speaker == nil) // partials never carry a speaker
            }
        }
        #expect(sawLabeledFinal)
    }

    @Test func finalHasNoSpeakerWithoutIdentifier() async throws {
        let pipeline = TranscriptionPipeline(source: OneShotSource(), engine: StubEngine())
        let stream = try await pipeline.start()
        var sawFinal = false
        for await event in stream {
            if case let .final(_, _, _, speaker) = event {
                #expect(speaker == nil)
                sawFinal = true
            }
        }
        #expect(sawFinal)
    }
}
