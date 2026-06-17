import AudioToolbox
import AVFoundation
import CoreAudio

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

    /// A specific input device to bind to (by uid), or nil to follow the system
    /// default. When the chosen device is gone (unplugged), we fall back to the
    /// default rather than starving on nothing.
    private let preferredDeviceUID: String?

    public init(preferredDeviceUID: String? = nil) {
        self.preferredDeviceUID = preferredDeviceUID
    }

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
        // Bind a specific input device if the user picked one. Use the v3
        // AUAudioUnit deviceID setter, NOT the v2 kAudioOutputUnitProperty_
        // CurrentDevice property: AVAudioEngine owns this unit's lifecycle and
        // tracks the v3 unit, so setDeviceID refreshes the engine's cached
        // input format to the new device. Poking the v2 audio unit directly
        // (with or without an uninit/init dance) does NOT refresh that cache —
        // the tap then reads the OLD device's format and yields silence, and
        // manually toggling the v2 unit's init state can desync the engine so
        // the tap never fires at all (both live-confirmed 2026-06-17: EarPods
        // and built-in mic went flat). A missing uid leaves the default in
        // place (graceful fallback).
        if let uid = preferredDeviceUID,
           let deviceID = AudioDevices.deviceID(forUID: uid) {
            do {
                try input.auAudioUnit.setDeviceID(deviceID)
            } catch {
                throw AudioCaptureError.deviceBindFailed(OSStatus((error as NSError).code))
            }
        }
        let nativeFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            throw AudioCaptureError.converterSetupFailed
        }

        // Build the converter from the format the tap ACTUALLY delivers, not
        // from inputFormat(forBus:): right after a device switch the two can
        // still disagree for a beat, and resampling from the wrong rate yields
        // silence. Rebuild if the hardware format changes mid-stream. Only the
        // tap's (serial) render thread touches `converter`, so the bare var is
        // safe.
        var converter: PipelineFormatConverter?
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = PipelineFormatConverter(from: buffer.format)
            }
            guard let converted = converter?.convert(buffer) else { return }
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
        // Ignore the benign echo we cause ourselves: binding the chosen device
        // via setDeviceID posts this notification (delivered async, after the
        // observer is registered), but the engine keeps running and the tap is
        // intact — rebuilding here would re-set the device, post another change,
        // and churn until a transient start failure kills the stream (live:
        // explicit EarPods captured ONE buffer then went flat, 2026-06-17). The
        // lazy converter already adapts to any live format drift. Only rebuild
        // when the engine actually STOPPED — the real "default device went away"
        // case this handler exists for.
        guard !changed.isRunning else { return }
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
