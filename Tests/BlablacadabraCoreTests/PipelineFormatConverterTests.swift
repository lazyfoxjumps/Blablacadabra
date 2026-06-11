import AVFoundation
import Testing
@testable import BlablacadabraCore

/// 48 kHz stereo non-interleaved Float32 is what SCStream actually delivers.
private let scStreamLikeFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, hz: Double = 440) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(format.channelCount) {
        let data = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            data[i] = Float(sin(2 * .pi * hz * Double(i) / format.sampleRate))
        }
    }
    return buffer
}

@Suite struct PipelineFormatConverterTests {
    @Test func convertsToPipelineFormat() throws {
        let converter = try #require(PipelineFormatConverter(from: scStreamLikeFormat))
        let input = makeSineBuffer(format: scStreamLikeFormat, frames: 4800) // 100ms

        let out = try #require(converter.convert(input))
        #expect(out.format.sampleRate == 16_000)
        #expect(out.format.channelCount == 1)
        #expect(out.format.commonFormat == .pcmFormatFloat32)
    }

    @Test func preservesDurationAcrossBufferStream() throws {
        let converter = try #require(PipelineFormatConverter(from: scStreamLikeFormat))
        // 50 x 100ms buffers = 5s in -> expect ~5s out (80,000 frames at 16kHz).
        var outFrames: AVAudioFrameCount = 0
        for _ in 0..<50 {
            let input = makeSineBuffer(format: scStreamLikeFormat, frames: 4800)
            if let out = converter.convert(input) {
                outFrames += out.frameLength
            }
        }
        let expected: AVAudioFrameCount = 80_000
        // The resampler holds back a filter window's worth of frames; allow 1%.
        #expect(outFrames > expected - expected / 100)
        #expect(outFrames <= expected)
    }

    @Test func signalSurvivesConversion() throws {
        let converter = try #require(PipelineFormatConverter(from: scStreamLikeFormat))
        let input = makeSineBuffer(format: scStreamLikeFormat, frames: 48_000) // 1s, full amplitude

        let out = try #require(converter.convert(input))
        let data = out.floatChannelData![0]
        var peak: Float = 0
        for i in 0..<Int(out.frameLength) { peak = max(peak, abs(data[i])) }
        #expect(peak > 0.5, "440Hz sine should survive resampling with most of its amplitude")
    }

    @Test func emptyBufferReturnsNil() throws {
        let converter = try #require(PipelineFormatConverter(from: scStreamLikeFormat))
        let empty = AVAudioPCMBuffer(pcmFormat: scStreamLikeFormat, frameCapacity: 0)!
        #expect(converter.convert(empty) == nil)
    }
}
