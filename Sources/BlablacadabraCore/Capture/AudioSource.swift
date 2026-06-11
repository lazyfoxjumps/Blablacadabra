import AVFoundation

/// The one audio format the rest of the pipeline speaks: 16 kHz mono Float32,
/// which is what WhisperKit expects as input.
public enum AudioPipelineFormat {
    public static let sampleRate: Double = 16_000
    public static let channels: AVAudioChannelCount = 1

    public static var format: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }
}

/// A source of live audio, already converted to the pipeline format
/// (16 kHz mono Float32). System audio and the mic both conform, so the
/// transcription layer never cares where the sound came from.
public protocol AudioSource: AnyObject {
    /// Starts capturing and returns a stream of pipeline-format PCM buffers.
    /// The stream finishes when `stop()` is called or the source fails.
    func start() async throws -> AsyncStream<AVAudioPCMBuffer>

    /// Stops capturing and finishes the buffer stream.
    func stop() async
}

public enum AudioCaptureError: LocalizedError {
    case screenRecordingPermissionDenied
    case noDisplayFound
    case alreadyRunning
    case converterSetupFailed

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required to capture system audio. Enable it in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .noDisplayFound:
            return "No display available for system audio capture."
        case .alreadyRunning:
            return "Capture is already running."
        case .converterSetupFailed:
            return "Could not set up audio format conversion."
        }
    }
}
