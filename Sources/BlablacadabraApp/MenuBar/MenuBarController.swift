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
            button.image = NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: "Blablacadabra"
            ) ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Blablacadabra")
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
        let symbol: String
        switch state.phase {
        case .listening, .starting: symbol = "captions.bubble.fill"
        default: symbol = "captions.bubble"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Blablacadabra"
        ) ?? statusItem.button?.image
    }
}
