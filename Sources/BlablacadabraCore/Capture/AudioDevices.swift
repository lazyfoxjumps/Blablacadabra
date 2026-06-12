import CoreAudio
import Foundation

/// One CoreAudio device, as much as the Audio settings UI needs: a stable uid
/// (survives unplug/replug, so a remembered choice still resolves), a friendly
/// name, and whether it can do input/output.
public struct AudioDevice: Sendable, Equatable, Identifiable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let hasInput: Bool
    public let hasOutput: Bool

    public init(id: AudioDeviceID, uid: String, name: String, hasInput: Bool, hasOutput: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.hasInput = hasInput
        self.hasOutput = hasOutput
    }
}

/// CoreAudio device enumeration for the Audio settings section. The project had
/// no device listing before this (capture always used the system default), so
/// this is the one place that talks to `kAudioHardwarePropertyDevices`.
public enum AudioDevices {
    /// Input-capable devices, for the microphone picker.
    public static func inputDevices() -> [AudioDevice] {
        allDevices().filter { $0.hasInput }
    }

    /// The current system default OUTPUT device, used to warn about
    /// capture-breaking virtual outputs (see `isCaptureBreaking`).
    public static func defaultOutputDevice() -> AudioDevice? {
        guard let id = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return device(for: id)
    }

    /// The current system default INPUT device (what "Automatic" follows).
    public static func defaultInputDevice() -> AudioDevice? {
        guard let id = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return device(for: id)
    }

    /// Resolve a device id from a remembered uid (nil if it's gone, e.g.
    /// unplugged), so the mic picker degrades to the system default instead of
    /// binding to nothing.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { $0.uid == uid }?.id
    }

    /// Virtual output devices that silently break system-audio capture (the
    /// foxpro 24 kHz virtual device on this Mac is the known offender, Handoff
    /// gotcha 8): while one is the default output, SCStream delivers mislabeled
    /// or zero audio. Matched by name substring, case-insensitive.
    public static let captureBreakingDeviceNames = ["foxpro"]

    public static func isCaptureBreaking(_ device: AudioDevice) -> Bool {
        let name = device.name.lowercased()
        return captureBreakingDeviceNames.contains { name.contains($0) }
    }

    // MARK: - Enumeration

    public static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { device(for: $0) }
    }

    // MARK: - Per-device queries

    private static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
            hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
        )
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else { return 0 }

        let pointer = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return pointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Watches a CoreAudio default-device property (input or output) and fires a
/// handler on the main queue when it changes, so the Audio settings section can
/// surface device switches instead of letting them happen silently (an ND rule:
/// a state change is never invisible). Removes its listener on deinit.
public final class DefaultDeviceObserver {
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    /// `selector` is typically `kAudioHardwarePropertyDefaultInputDevice` or
    /// `kAudioHardwarePropertyDefaultOutputDevice`.
    public init(selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }
}
