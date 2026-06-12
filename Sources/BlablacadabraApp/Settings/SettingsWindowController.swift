import AppKit
import SwiftUI

/// Plain titled window for settings; created lazily, reused after close.
final class SettingsWindowController: NSWindowController {
    convenience init(state: AppState, resetOverlayPosition: @escaping () -> Void) {
        let host = NSHostingController(
            rootView: SettingsView(state: state, resetOverlayPosition: resetOverlayPosition)
        )
        let window = NSWindow(contentViewController: host)
        // Card look from the mockups, but with the app name sitting next to
        // the traffic lights like any other app (Loft Hours pattern). The
        // empty unified toolbar is what pulls the title left, beside the
        // buttons, instead of centered.
        window.title = "blablacadabra"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Don't let AppKit hand initial key focus to a control mid-page; that
        // silently scrolls the settings away from the top on open.
        window?.makeFirstResponder(nil)
    }
}
