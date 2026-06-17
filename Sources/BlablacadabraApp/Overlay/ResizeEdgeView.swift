import AppKit

/// An invisible vertical strip pinned to the left or right edge of the caption
/// panel that resizes the card's WIDTH on drag. Lives at the AppKit layer (not
/// SwiftUI) on purpose: the panel sets `isMovableByWindowBackground`, which eats
/// mouseDown for window-dragging before a SwiftUI gesture can claim it, and that
/// race is exactly why the old SwiftUI corner handles only worked on one corner.
/// An NSView that returns `mouseDownCanMoveWindow = false` reliably wins the
/// mouseDown on its own bounds, so all of the card's side edges resize.
///
/// No visible chrome (the user didn't want a bracket frame). Discoverability is
/// the cursor: hovering the strip shows the horizontal resize arrow. Only width
/// changes (height hugs the captions), so the honest cursor is `resizeLeftRight`,
/// not a diagonal one.
@MainActor
final class ResizeEdgeView: NSView {
    enum Edge { case left, right }

    private let edge: Edge
    /// Called with the desired new width and whether the RIGHT edge is the one
    /// that should move (left edge stays put). Mirrors `AppState.overlayResizeHandler`.
    private let onResize: (CGFloat, Bool) -> Void
    private let minWidth: CGFloat

    private var dragStartWidth: CGFloat = 0
    private var dragStartMouseX: CGFloat = 0

    init(edge: Edge, minWidth: CGFloat, onResize: @escaping (CGFloat, Bool) -> Void) {
        self.edge = edge
        self.minWidth = minWidth
        self.onResize = onResize
        super.init(frame: .zero)
        wantsLayer = true // transparent; just here for hit-testing + cursor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // Claim the mouseDown instead of letting the window drag-to-move eat it.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            // activeAlways: the overlay is a nonactivating panel, so the cursor
            // must update even when the app isn't frontmost.
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: Drag to resize

    override func mouseDown(with event: NSEvent) {
        dragStartWidth = window?.frame.width ?? bounds.width
        dragStartMouseX = NSEvent.mouseLocation.x // screen coords; stable across the drag
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = NSEvent.mouseLocation.x - dragStartMouseX
        // Left edge dragged left (dx<0) grows the card; right edge dragged right
        // (dx>0) grows it. The handler keeps the opposite edge anchored.
        let delta = (edge == .left) ? -dx : dx
        let newWidth = max(minWidth, dragStartWidth + delta)
        onResize(newWidth, edge == .right)
        NSCursor.resizeLeftRight.set() // hold the cursor through the drag
    }
}
