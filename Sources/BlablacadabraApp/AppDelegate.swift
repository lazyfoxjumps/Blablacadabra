import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var menuBar: MenuBarController!
    private var overlay: OverlayPanelController!
    private var settingsController: SettingsWindowController?
    private var onboardingWindow: NSWindow?
    private let hotkey = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no app menu (the LSUIElement shape;
        // the plist flag in the bundled build keeps launch services agreeing).
        NSApp.setActivationPolicy(.accessory)

        // Nunito body + Jua headings, bundled in Resources/Fonts.
        AppFont.registerBundledFonts()

        state = AppState()
        overlay = OverlayPanelController(state: state)
        menuBar = MenuBarController(state: state) { [weak self] in
            self?.showSettings()
        }

        hotkey.onHotkey = { [weak self] in
            self?.state.toggleCaptions()
        }
        hotkey.register()

        if !state.hasOnboarded {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stopCaptions()
    }

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(state: state) { [weak self] in
                self?.overlay.resetPosition()
            }
        }
        settingsController?.present()
    }

    private func showOnboarding() {
        let host = NSHostingController(
            rootView: OnboardingView(state: state) { [weak self] in
                self?.state.hasOnboarded = true
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Welcome to Blablacadabra"
        // Same borderless-card chrome as settings.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
