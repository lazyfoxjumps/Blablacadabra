import AppKit
import Combine
import SwiftUI

/// The status item and its panel: the whole app lives behind one menu-bar
/// icon (LSUIElement shell, no Dock presence).
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState, openSettings: @escaping () -> Void) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.brandIcon(active: false)
            button.toolTip = "Blablacadabra · Now you hear it, now you read it."
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(state: state, openSettings: openSettings)
        )

        // Icon mirrors session state so "is it on?" never needs a click.
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncIcon() }
            }
            .store(in: &subscriptions)
    }

    // TEMP screenshot hook (remove before commit): lets AppDelegate open the
    // panel without a real menu-bar click.
    func openPanelForScreenshot() {
        togglePopover()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func syncIcon() {
        // Solid burst while a session is live (captioning/translating), hollow
        // outline when idle. Brand favicon, not an SF Symbol.
        let active: Bool
        switch state.phase {
        case .listening, .starting: active = true
        default: active = false
        }
        if let icon = Self.brandIcon(active: active) {
            statusItem.button?.image = icon
        }
    }

    /// The menu-bar mark: brand favicon star rendered as a monochrome TEMPLATE
    /// (the menu bar tints it for light/dark + active highlight). Solid when a
    /// session is live, outline-only when idle. Falls back to the old SF Symbol
    /// when run outside the .app bundle (e.g. `swift run`), where the SVGs
    /// aren't on disk.
    private static func brandIcon(active: Bool) -> NSImage? {
        let name = active ? "MenuIcon-Filled" : "MenuIcon-Outline"
        if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logo"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Blablacadabra"
            return image
        }
        let symbol = active ? "captions.bubble.fill" : "captions.bubble"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "Blablacadabra")
            ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Blablacadabra")
    }
}
