import AVFoundation

/// Converts arbitrary-format PCM buffers (e.g. SCStream's 48 kHz stereo
/// non-interleaved Float32, or the mic's native format) into the pipeline
/// format: 16 kHz mono Float32. Stateful because sample-rate conversion
/// carries filter state between buffers; feed it one stream only.
final class PipelineFormatConverter {
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: AudioPipelineFormat.format) else {
            return nil
        }
        self.converter = converter
        self.ratio = AudioPipelineFormat.sampleRate / inputFormat.sampleRate
    }

    /// Returns a pipeline-format buffer, or nil for empty/failed conversions
    /// (a resampler can legitimately emit zero frames for a tiny input buffer
    /// while it fills its internal filter window).
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioPipelineFormat.format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
