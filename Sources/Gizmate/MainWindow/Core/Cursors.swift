import AppKit
import SwiftUI

/// What the pointer says about the thing under it.
///
/// Gizmate had no answer to that anywhere except one card in the live panel:
/// three `NSCursor` calls in the whole source, all of them in
/// `LiveCaptionViews`. Everything else — every button, every tab, every card
/// you can pick up — left the arrow alone, so nothing on screen ever admitted
/// to being pressable or draggable until it was pressed or dragged.
///
/// The mechanism matters as much as the coverage, which is why this is a
/// tracking area rather than the obvious `.onHover { NSCursor.push() }`:
///
/// - **`.activeAlways`.** Gizmate's panels and docks are `.nonactivatingPanel`,
///   and the app itself is an accessory that is often not the active one. A
///   tracking area installed for the active app only would go quiet exactly
///   where this app does most of its work — over a dock while the user is still
///   "in" Safari. Hover-driven cursors would have looked broken there and
///   nowhere else, which is the hardest kind of broken to explain.
/// - **`set()`, not `push()`/`pop()`.** A pushed cursor has to be popped by the
///   same view, and a SwiftUI view can be torn down mid-hover — a card the
///   pointer is over while the list reorders under it, say. One missed pop and
///   the wrong cursor sticks for the rest of the session. `cursorUpdate` is
///   AppKit asking "what should the pointer be right now"; answering it needs
///   no bookkeeping and nothing to leak.
///
/// macOS conventions, for anything added later: `pointingHand` for a thing that
/// acts when clicked, `openHand` for a thing you can pick up.
final class CursorTrackingView: NSView {
    var cursor: NSCursor = .arrow
    /// Set by `attach`: re-take the host's bounds on every geometry pass.
    /// An autoresizing mask cannot do it — the host's frame is routinely still
    /// zero when the tracker goes in, and a mask distributes deltas rather than
    /// setting a size, so it would stay zero forever. Same self-healing shape
    /// `DockContentView` uses, and for the same reason.
    private var fillsHost = false

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if fillsHost, let superview, frame != superview.bounds {
            frame = superview.bounds
        }
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    /// Never takes a click. It is described as sitting *behind* its content,
    /// and a plain `NSView` would still hit-test for a point over transparent
    /// pixels — which is every button whose label does not fill its frame. A
    /// tracking area is geometry and does not need hit-testing to fire.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// Installs the same behaviour on a view that already exists — the AppKit
    /// half of the app, where the button *is* the view and cannot be wrapped.
    static func attach(_ cursor: NSCursor, to view: NSView) {
        view.subviews.compactMap { $0 as? CursorTrackingView }.forEach { $0.removeFromSuperview() }
        let area = CursorTrackingView(frame: view.bounds)
        area.cursor = cursor
        area.fillsHost = true
        view.addSubview(area)
    }
}

private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorTrackingView {
        let view = CursorTrackingView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ view: CursorTrackingView, context: Context) {
        view.cursor = cursor
    }
}

extension View {
    /// The pointer this view claims while it is under it.
    ///
    /// Sits in the background rather than an overlay so it can never take a
    /// click off the thing it is describing. A tracking area is geometry, not
    /// hit-testing, so being behind the content costs it nothing.
    func cursor(_ cursor: NSCursor) -> some View {
        background(CursorArea(cursor: cursor))
    }

    /// The plain button style and the pointer that should always have come
    /// with it, in one call so the two cannot be applied separately — which,
    /// over 70 call sites, is the only way they stay applied together.
    func plainButton() -> some View {
        buttonStyle(.plain).cursor(.pointingHand)
    }
}
