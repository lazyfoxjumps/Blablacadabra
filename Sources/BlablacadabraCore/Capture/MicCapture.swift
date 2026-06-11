import AVFoundation

/// Optional second audio source: the microphone, for captioning in-person
/// speech. Taps `AVAudioEngine`'s input node and emits 16 kHz mono Float32.
///
/// Requires Microphone permission; see `CapturePermissions`.
public final class MicCapture: AudioSource {
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init() {}

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard engine == nil else { throw AudioCaptureError.alreadyRunning }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)
        guard let converter = PipelineFormatConverter(from: nativeFormat) else {
            throw AudioCaptureError.converterSetupFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            self?.continuation?.yield(converted)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    public func stop() async {
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
