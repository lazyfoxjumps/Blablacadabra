import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures everything the Mac plays (any app, any website, FaceTime) via
/// ScreenCaptureKit and emits 16 kHz mono Float32 buffers ready for Whisper.
///
/// Requires Screen Recording permission; see `CapturePermissions`.
public final class SystemAudioCapture: NSObject, AudioSource {
    // `stream`, `continuation`, and `converter` are touched from the audio
    // sample-handler callback (on `sampleQueue`), from `start()`/`stop()` (the
    // caller's thread), and from the `didStopWithError` delegate callback (an
    // internal SCStream queue). All access is confined to `sampleQueue` so those
    // threads never race on them — mirrors how `MicCapture` serializes its state.
    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var converter: PipelineFormatConverter?
    private let sampleQueue = DispatchQueue(label: "blablacadabra.system-audio")

    public override init() {
        super.init()
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard sampleQueue.sync(execute: { self.stream == nil }) else {
            throw AudioCaptureError.alreadyRunning
        }

        // SCShareableContent.current is also the permission gate: it throws
        // if Screen Recording access is missing.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw AudioCaptureError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStream requires a video track even for audio-only capture; make it
        // as cheap as possible (2x2 px, 1 fps).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        sampleQueue.sync { self.stream = stream }

        return AsyncStream { continuation in
            sampleQueue.sync { self.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                // Consumer walked away (task cancelled, loop broken): tear down
                // capture rather than yielding into the void.
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    public func stop() async {
        // Claim the stream on `sampleQueue` so a concurrent stop / didStopWithError
        // can't double-stop or race the teardown.
        let stream: SCStream? = sampleQueue.sync {
            let s = self.stream
            self.stream = nil
            return s
        }
        guard let stream else { return }
        // stopCapture is async, so it can't run inside the sync block; once it
        // returns no more sample callbacks fire, then we finish the stream.
        try? await stream.stopCapture()
        sampleQueue.sync {
            self.converter = nil
            self.continuation?.finish()
            self.continuation = nil
        }
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let described = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(described) else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(numSamples),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        // The stream format can change mid-capture (default output device
        // switch, sample-rate change); a converter built for the old format
        // silently produces wrong-rate audio, so rebuild on any change.
        if converter == nil || converter?.inputFormat != format {
            converter = PipelineFormatConverter(from: format)
        }
        guard let converted = converter?.convert(pcm) else { return }
        continuation?.yield(converted)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Display change, permission revoked mid-stream, etc. This delegate
        // callback arrives on SCStream's internal queue, so hop onto sampleQueue
        // to tear down without racing the sample callback or stop().
        sampleQueue.async {
            self.stream = nil
            self.converter = nil
            self.continuation?.finish()
            self.continuation = nil
        }
    }
}
