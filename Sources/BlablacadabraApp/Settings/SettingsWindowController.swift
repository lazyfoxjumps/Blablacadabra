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
        // Borderless-card look from the mockups: the content draws its own
        // header; the system title bar goes transparent but keeps the close
        // button (never trap the user in a window).
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
