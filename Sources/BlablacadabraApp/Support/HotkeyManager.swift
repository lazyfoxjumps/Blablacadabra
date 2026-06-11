import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon (still the sanctioned API for system-wide
/// hotkeys without the Accessibility permission an event tap would need).
/// One hotkey, fixed: Option-Command-C toggles captions from anywhere.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotkey: (() -> Void)?

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkey?() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x424C_424C), id: 1) // 'BLBL'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
