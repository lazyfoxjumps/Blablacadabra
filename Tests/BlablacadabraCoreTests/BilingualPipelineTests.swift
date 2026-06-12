import AVFoundation
import Testing
@testable import BlablacadabraCore

/// A fake engine that records which tasks it was asked for and returns canned
/// text, so the pipeline's translate / transcribe / detect orchestration can
/// be checked without loading a model.
private actor FakeEngine: TranscriptionEngine {
    let englishText: String
    let originalText: String
    let sourceLanguage: String
    private(set) var translateCalls = 0
    private(set) var transcribeCalls = 0
    private(set) var detectCalls = 0

    init(english: String, original: String, language: String) {
        self.englishText = english
        self.originalText = original
        self.sourceLanguage = language
    }

    func prepare() async throws {}

    func transcribe(_ samples: [Float], task: TranscriptionTask, language: String?) async throws -> TranscriptionOutput {
        switch task {
        case .translate:
            translateCalls += 1
            // The translate task reports the TARGET language, like WhisperKit.
            return TranscriptionOutput(text: englishText, detectedLanguage: "en")
        case .transcribe:
            transcribeCalls += 1
            return TranscriptionOutput(text: originalText, detectedLanguage: language ?? sourceLanguage)
        }
    }

    func detectLanguage(_ samples: [Float]) async throws -> String? {
        detectCalls += 1
        return sourceLanguage
    }

    var counts: (translate: Int, transcribe: Int, detect: Int) {
        (translateCalls, transcribeCalls, detectCalls)
    }
}

/// Plays a fixed list of buffers, then ends. One buffer of speech-like audio
/// long enough to clear the VAD's minimum and produce a single final on flush.
private actor ScriptedSource: AudioSource {
    func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioPipelineFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            let frames = AVAudioFrameCount(AudioPipelineFormat.sampleRate) // 1s
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

/// Two speech bursts separated by enough silence to finalize the first, so the
/// pipeline produces two finals from one playback (for checking that auto-mode
/// language detection runs once and is cached, not re-run per utterance).
private actor TwoUtteranceSource: AudioSource {
    func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioPipelineFormat.sampleRate,
                channels: 1,
                interleaved: false
            )!
            let rate = Int(AudioPipelineFormat.sampleRate)
            func speech(_ secs: Double) -> [Float] {
                (0..<Int(Double(rate) * secs)).map { $0 % 2 == 0 ? 0.2 : -0.2 }
            }
            func silence(_ secs: Double) -> [Float] {
                [Float](repeating: 0, count: Int(Double(rate) * secs))
            }
            // 0.8s gap clears the 0.6s finalize threshold between the bursts.
            let samples = speech(1.0) + silence(0.8) + speech(1.0)
            let frames = AVAudioFrameCount(samples.count)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let ptr = buffer.floatChannelData![0]
            for (i, sample) in samples.enumerated() { ptr[i] = sample }
            continuation.yield(buffer)
            continuation.finish()
        }
    }

    func stop() async {}
}

private func collect(_ pipeline: TranscriptionPipeline) async throws -> [CaptionEvent] {
    let stream = try await pipeline.start()
    var events: [CaptionEvent] = []
    for await event in stream { events.append(event) }
    return events
}

@Suite struct BilingualPipelineTests {
    @Test func bilingualFinalCarriesOriginalAndSourceLanguage() async throws {
        let engine = FakeEngine(english: "Hello, my name is Tanaka.", original: "私の名前は田中です。", language: "ja")
        let pipeline = TranscriptionPipeline(
            source: ScriptedSource(), engine: engine, task: .translate, showOriginal: true
        )
        let finals = try await collect(pipeline).compactMap { event -> (String, String?, String?)? in
            if case let .final(text, original, language) = event { return (text, original, language) }
            return nil
        }
        #expect(finals.count == 1)
        #expect(finals[0].0 == "Hello, my name is Tanaka.")
        #expect(finals[0].1 == "私の名前は田中です。")
        #expect(finals[0].2 == "ja")
        // Bilingual finals: detect once, then force that language on the
        // translate AND transcribe passes.
        let counts = await engine.counts
        #expect(counts.detect == 1)
        #expect(counts.translate == 1)
        #expect(counts.transcribe == 1)
    }

    @Test func translateWithoutOriginalUsesDetectForLanguage() async throws {
        let engine = FakeEngine(english: "Tokyo Station, where is it?", original: "東京駅はどこですか。", language: "ja")
        let pipeline = TranscriptionPipeline(
            source: ScriptedSource(), engine: engine, task: .translate, showOriginal: false
        )
        let finals = try await collect(pipeline).compactMap { event -> (String, String?, String?)? in
            if case let .final(text, original, language) = event { return (text, original, language) }
            return nil
        }
        #expect(finals.count == 1)
        #expect(finals[0].0 == "Tokyo Station, where is it?")
        #expect(finals[0].1 == nil) // no original line
        #expect(finals[0].2 == "ja") // language came from detect, not translate
        let counts = await engine.counts
        #expect(counts.detect == 1)
        #expect(counts.translate == 1)
        #expect(counts.transcribe == 0) // no original line requested
    }

    @Test func plainTranscriptionDetectsThenTranscribes() async throws {
        let engine = FakeEngine(english: "ignored", original: "Hallo, ich heisse Anna.", language: "de")
        let pipeline = TranscriptionPipeline(
            source: ScriptedSource(), engine: engine, task: .transcribe, showOriginal: true
        )
        let finals = try await collect(pipeline).compactMap { event -> (String, String?)? in
            if case let .final(text, _, language) = event { return (text, language) }
            return nil
        }
        #expect(finals.count == 1)
        #expect(finals[0].0 == "Hallo, ich heisse Anna.")
        #expect(finals[0].1 == "de")
        let counts = await engine.counts
        #expect(counts.translate == 0) // never translates in transcribe mode
        #expect(counts.detect == 1)
        #expect(counts.transcribe == 1)
    }

    @Test func lockedLanguageSkipsDetectionEntirely() async throws {
        let engine = FakeEngine(english: "ignored", original: "Apa kabar?", language: "id")
        let pipeline = TranscriptionPipeline(
            source: ScriptedSource(), engine: engine, task: .transcribe,
            spokenLanguage: "id", showOriginal: false
        )
        let finals = try await collect(pipeline).compactMap { event -> (String, String?)? in
            if case let .final(text, _, language) = event { return (text, language) }
            return nil
        }
        #expect(finals.count == 1)
        #expect(finals[0].0 == "Apa kabar?")
        #expect(finals[0].1 == "id") // reported language is the locked one
        let counts = await engine.counts
        // The whole point: a locked language never spends a detection pass.
        #expect(counts.detect == 0)
        #expect(counts.transcribe == 1)
    }

    @Test func autoModeDetectsOnceAndReusesIt() async throws {
        let engine = FakeEngine(english: "Hello.", original: "Halo.", language: "id")
        let pipeline = TranscriptionPipeline(
            source: TwoUtteranceSource(), engine: engine, task: .translate, showOriginal: false
        )
        let finals = try await collect(pipeline).filter { event in
            if case .final = event { return true }
            return false
        }
        #expect(finals.count == 2) // two utterances
        let counts = await engine.counts
        // Detect runs on the first final only; the second reuses the cache.
        #expect(counts.detect == 1)
    }
}
