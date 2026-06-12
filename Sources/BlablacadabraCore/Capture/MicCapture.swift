import AVFoundation

/// Optional second audio source: the microphone, for captioning in-person
/// speech. Taps `AVAudioEngine`'s input node and emits 16 kHz mono Float32.
///
/// Follows the default input device: when the user switches mics mid-session
/// (or the device's format changes), AVAudioEngine stops and the tap goes
/// silent without an error. Verified live 2026-06-12: without handling, the
/// stream just starves forever. So on `AVAudioEngineConfigurationChange` the
/// engine is rebuilt on the new default input and keeps feeding the same
/// stream. If the rebuild fails (e.g. no input device left), the stream
/// finishes so the pipeline can surface its "lost the audio" state instead
/// of listening to nothing.
///
/// Requires Microphone permission; see `CapturePermissions`.
public final class MicCapture: AudioSource {
    private let queue = DispatchQueue(label: "blablacadabra.mic-capture")
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var configObserver: (any NSObjectProtocol)?
    private var running = false

    public init() {}

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        try queue.sync {
            guard !running else { throw AudioCaptureError.alreadyRunning }
            try startEngineLocked()
            running = true
        }
        return AsyncStream { continuation in
            queue.sync { self.continuation = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.stop() }
            }
        }
    }

    public func stop() async {
        queue.sync {
            guard running else { return }
            running = false
            tearDownEngineLocked()
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - Engine lifecycle (all on `queue`)

    private func startEngineLocked() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let nativeFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0,
              let converter = PipelineFormatConverter(from: nativeFormat) else {
            throw AudioCaptureError.converterSetupFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = converter.convert(buffer) else { return }
            self.queue.async { self.continuation?.yield(converted) }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.handleConfigurationChangeLocked(of: engine) }
        }
    }

    private func tearDownEngineLocked() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func handleConfigurationChangeLocked(of changed: AVAudioEngine) {
        // Stale notification for an engine we already replaced or stopped.
        guard running, engine === changed else { return }
        tearDownEngineLocked()
        do {
            // The new default input may need a beat to come up; one retry
            // covers the switchover gap without spinning.
            try startEngineLocked()
        } catch {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.running, self.engine == nil else { return }
                if (try? self.startEngineLocked()) == nil {
                    self.running = false
                    self.continuation?.finish()
                    self.continuation = nil
                }
            }
        }
    }
}
