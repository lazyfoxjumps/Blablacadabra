import AppKit
import SwiftUI

/// Plain titled window for settings; created lazily, reused after close.
final class SettingsWindowController: NSWindowController {
    convenience init(state: AppState, resetOverlayPosition: @escaping () -> Void) {
        let host = NSHostingController(
            rootView: SettingsView(state: state, resetOverlayPosition: resetOverlayPosition)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Blablacadabra settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
