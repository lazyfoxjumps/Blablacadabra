import AppKit
import Combine
import SwiftUI

/// Borderless floating NSPanel hosting the caption card: always on top,
/// joins every Space (FaceTime fullscreen included), draggable by its
/// background, optional click-through. Visible whenever a session exists
/// (listening, paused, or stuck on a fixable state); hidden when idle.
///
/// Fixed width (`AppState.overlayWidth`); height hugs the SwiftUI content
/// (`.preferredContentSize`). User-resize was tried and shelved (a borderless
/// always-on-top panel fights the OS resize machinery too hard to be reliable).
@MainActor
final class OverlayPanelController: NSObject {
    private let panel: NSPanel
    private let state: AppState
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state

        let host = NSHostingController(rootView: OverlayView(state: state))
        host.sizingOptions = [.preferredContentSize]

        panel = NSPanel(contentViewController: host)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // No autosave: persisting the frame would also persist a width a prior
        // (resizable) build let the user stretch to. Fixed width means we only
        // need to place it once, below.
        super.init()

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            // First launch: bottom-center, clear of the Dock.
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.minY + 80
            ))
        }

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &subscriptions)
        sync()
    }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 80
        ))
    }

    private func sync() {
        panel.ignoresMouseEvents = state.clickThrough
        if state.phase == .idle {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
}
