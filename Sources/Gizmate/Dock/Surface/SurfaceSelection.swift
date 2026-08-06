import AppKit
import SwiftUI

/// Multi-select and multi-file drag for a surface's cards, installed by the
/// host through the environment the same way `surfaceActivate` is.
///
/// SwiftUI has no expression for dragging more than one thing: `.onDrag`
/// returns exactly one `NSItemProvider`, and one provider is one item however
/// many representations it registers — `.draggable` is the same shape. Five
/// files out of the shelf is `beginDraggingSession` with five
/// `NSDraggingItem`s, which is AppKit or nothing. So where a host installs
/// this, the card hands its *whole* mouse story to `SurfaceCardMouse` —
/// select, activate and drag together — rather than keep half of it in
/// SwiftUI gestures the overlay would swallow anyway.
struct SurfaceSelection: Equatable {
    /// Compared by the selection alone. The closures are rebuilt on every
    /// render of the host and can never compare equal, so without this an
    /// environment value carrying them counts as changed whenever *anything*
    /// in the host changes — a chip hovering, a chip arming — and every card
    /// on the shelf re-evaluates for it. Ignoring them is safe because they
    /// hold no captured state of their own: each one reads the host's
    /// `@State` through its storage box, so a "stale" closure still sees the
    /// current selection and the current rows.
    static func == (lhs: SurfaceSelection, rhs: SurfaceSelection) -> Bool {
        lhs.ids == rhs.ids
    }

    /// The row ids lit right now — a snapshot, re-handed on every render.
    var ids: Set<String>
    /// A click landed on this row. `command` is held for a toggle; what a
    /// plain click means is the host's to decide, since the host owns both the
    /// selection and the order the rows are in.
    var click: (SurfaceRow, Bool) -> Void
    /// Told when the card's menu moved files to the Trash, so the host can drop
    /// them from what it is showing. `nil` means it worked.
    var onTrashed: ((Error?) -> Void)?
    /// The files a drag starting on this row should carry, in the order shown.
    /// Empty means no drag at all — a row with nothing to hand over must not
    /// start a session that drops nothing.
    var dragURLs: (SurfaceRow) -> [URL]
}

private struct SurfaceSelectionKey: EnvironmentKey {
    static let defaultValue: SurfaceSelection? = nil
}

extension EnvironmentValues {
    var surfaceSelection: SurfaceSelection? {
        get { self[SurfaceSelectionKey.self] }
        set { self[SurfaceSelectionKey.self] = newValue }
    }
}

/// The AppKit view that owns a selectable card's mouse.
struct SurfaceCardMouse: NSViewRepresentable {
    let row: SurfaceRow
    let selection: SurfaceSelection
    let activate: ((SurfaceRow) -> Void)?

    func makeNSView(context: Context) -> SurfaceCardMouseView {
        let view = SurfaceCardMouseView()
        update(view)
        return view
    }

    func updateNSView(_ view: SurfaceCardMouseView, context: Context) {
        update(view)
    }

    /// Re-handed on every render rather than captured once: each closure holds
    /// the selection as it was when the view tree was built, and a card whose
    /// handlers were frozen at first layout would drag whatever was selected
    /// the moment the panel opened.
    private func update(_ view: SurfaceCardMouseView) {
        view.isSelected = { selection.ids.contains(row.id) }
        view.onClick = { command in selection.click(row, command) }
        view.onActivate = { activate?(row) }
        view.urls = { selection.dragURLs(row) }
        view.onTrashed = selection.onTrashed
    }
}

final class SurfaceCardMouseView: NSView, NSDraggingSource {
    var isSelected: () -> Bool = { false }
    var onClick: (Bool) -> Void = { _ in }
    var onActivate: () -> Void = {}
    var urls: () -> [URL] = { [] }
    var onTrashed: ((Error?) -> Void)?

    /// The press a drag would start from, cleared once one has or the button
    /// came back up. Held rather than re-read because `beginDraggingSession`
    /// wants the *mouse-down* event, not the drag that crossed the threshold.
    private var pressed: NSEvent?
    /// A dragging session keeps its source only unowned, and this view's window
    /// closes out from under it by design — the dock hides as soon as the
    /// pointer leaves the panel, which is exactly the gesture a drag *is*. The
    /// self-reference outlives the hosting view so the end-of-session callback
    /// has something to land on.
    private var sessionRetain: SurfaceCardMouseView?
    /// A plain press landed on a card that was already selected, and the
    /// collapse to that one card is waiting to see whether a drag happens.
    private var collapseOnMouseUp = false

    /// The menu currently on screen, held strongly: an `NSMenuItem` targets
    /// its object weakly, so nothing else would keep the actions alive long
    /// enough to be clicked.
    private var menuTarget: FileActionMenu?

    /// The panel is non-activating, so without this the click that reaches a
    /// card from another app is spent activating Gizmate instead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Right-click. `urls()` applies Finder's own rule on the way — a card
    /// outside the selection becomes the selection — so the menu is always
    /// about what the user is looking at, never about a selection they left
    /// behind in another folder.
    override func menu(for event: NSEvent) -> NSMenu? {
        let target = FileActionMenu(urls: urls(), onTrashed: onTrashed)
        menuTarget = target
        return target.makeMenu()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        collapseOnMouseUp = false
        if event.clickCount == 2 {
            onActivate()
        } else if event.modifierFlags.contains(.command) {
            onClick(true)
        } else if isSelected() {
            // Finder's rule, and the whole reason multi-drag works at all: a
            // plain press on an already-selected card must not collapse the
            // selection, because the drag that may follow reads the selection
            // as it stands. Collapsing here is what made every drag carry
            // exactly one file no matter how many were lit. The collapse is
            // still owed — it just waits for a mouse-up no drag intervened in.
            collapseOnMouseUp = true
        } else {
            onClick(false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        // Three points of slop: a click with a shaky hand is a click, and
        // starting a drag session on it would eat the selection it just made.
        let delta = CGPoint(
            x: event.locationInWindow.x - pressed.locationInWindow.x,
            y: event.locationInWindow.y - pressed.locationInWindow.y
        )
        guard delta.x * delta.x + delta.y * delta.y > 9 else { return }
        self.pressed = nil
        // The press turned out to be a drag, so the collapse it owed is off.
        collapseOnMouseUp = false

        let files = urls()
        guard !files.isEmpty else { return }
        let origin = convert(pressed.locationInWindow, from: nil)
        let items = files.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // The file's own icon, not a snapshot of the card: a card is a
            // ~110pt square, and ten of them cascading under the pointer is a
            // wall. Finder drags icons for the same reason.
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let step = CGFloat(index) * 6
            item.setDraggingFrame(
                NSRect(x: origin.x - 24 + step, y: origin.y - 24 - step, width: 48, height: 48),
                contents: icon
            )
            return item
        }
        sessionRetain = self
        beginDraggingSession(with: items, event: pressed, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = nil
        guard collapseOnMouseUp else { return }
        collapseOnMouseUp = false
        onClick(false)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // What a shelf hands over: a copy anywhere, and the link a Finder
        // alias or a Terminal path drop asks for. Never `.move` — deleting the
        // user's file because a drop target preferred it is not a shelf's call.
        [.copy, .link, .generic]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        sessionRetain = nil
    }
}
