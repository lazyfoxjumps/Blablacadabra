import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures everything the Mac plays (any app, any website, FaceTime) via
/// ScreenCaptureKit and emits 16 kHz mono Float32 buffers ready for Whisper.
///
/// Requires Screen Recording permission; see `CapturePermissions`.
public final class SystemAudioCapture: NSObject, AudioSource {
    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var converter: PipelineFormatConverter?
    private let sampleQueue = DispatchQueue(label: "blablacadabra.system-audio")

    public override init() {
        super.init()
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard stream == nil else { throw AudioCaptureError.alreadyRunning }

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
        self.stream = stream

        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                // Consumer walked away (task cancelled, loop broken): tear down
                // capture rather than yielding into the void.
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        converter = nil
        continuation?.finish()
        continuation = nil
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

        if converter == nil {
            converter = PipelineFormatConverter(from: format)
        }
        guard let converted = converter?.convert(pcm) else { return }
        continuation?.yield(converted)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Display change, permission revoked mid-stream, etc.
        self.stream = nil
        converter = nil
        continuation?.finish()
        continuation = nil
    }
}
