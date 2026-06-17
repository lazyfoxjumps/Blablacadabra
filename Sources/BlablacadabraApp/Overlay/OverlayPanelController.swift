import AppKit
import Combine
import SwiftUI

/// Borderless floating NSPanel hosting the caption card: always on top,
/// joins every Space (FaceTime fullscreen included), draggable by its
/// background, optional click-through. Visible whenever a session exists
/// (listening, paused, or stuck on a fixable state); hidden when idle.
///
/// The card is user-resizable in width by dragging its edge; height always
/// hugs the SwiftUI content (`.preferredContentSize`). The width can't go below
/// `AppState.overlayMinWidth` (the original fixed size) and is persisted.
@MainActor
final class OverlayPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let state: AppState
    private var subscriptions: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state

        let host = NSHostingController(rootView: OverlayView(state: state))
        host.sizingOptions = [.preferredContentSize]

        panel = NSPanel(contentViewController: host)
        // `.resizable` lets the user drag the edge to widen; `windowWillResize`
        // pins height to the content and clamps the minimum width.
        panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: AppState.overlayMinWidth, height: 1)
        panel.setFrameAutosaveName("blablacadabra.overlay")

        super.init()
        panel.delegate = self

        // Wire the SwiftUI corner grippers' resize callback to this panel. The
        // grippers compute the desired width from their drag delta; we apply it
        // here so we can also shift the panel's origin when a LEFT corner is
        // the anchor (right edge stays put, left edge moves outward), matching
        // Canva-style stretch-from-corner behavior.
        state.overlayResizeHandler = { [weak self, weak panel] newWidth, anchorRight in
            guard let panel else { return }
            let clamped = max(CGFloat(AppState.overlayMinWidth), newWidth)
            var frame = panel.frame
            if anchorRight {
                frame.size.width = clamped
            } else {
                let delta = clamped - frame.size.width
                frame.origin.x -= delta
                frame.size.width = clamped
            }
            panel.setFrame(frame, display: true, animate: false)
            self?.state.overlayWidth = Double(clamped)
        }

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

    /// Width is the only axis the user controls; height follows the content. As
    /// the edge is dragged we clamp to the minimum and write the chosen width
    /// back to state so the SwiftUI frame (and `.preferredContentSize`) agree
    /// instead of snapping back.
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // AppKit calls this on the main thread, so it's safe to touch the
        // main-actor state and the window's frame here.
        MainActor.assumeIsolated {
            let width = max(AppState.overlayMinWidth, frameSize.width)
            if state.overlayWidth != width { state.overlayWidth = width }
            return NSSize(width: width, height: sender.frame.height)
        }
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
