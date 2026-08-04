import SwiftUI

/// The grab bar on a docked panel's inner edge.
///
/// A side dock stays open once you open it, so it needs a way out that is not
/// "move the mouse away" — and a way out nobody can see is not one. This is that
/// affordance: drag it toward the bezel and the panel goes back where it came
/// from.
///
/// The drag is measured from `NSEvent.mouseLocation` by the controller rather
/// than from the gesture's own translation: the controller moves the window
/// while the drag is in flight, and a translation measured inside a window that
/// is itself moving feeds back on itself.
struct DockDragHandle: View {
    let onDragChanged: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Capsule()
            .fill(FlowTheme.ink.opacity(hovering || dragging ? 0.55 : 0.25))
            .frame(width: 4, height: 38)
            // Wider than it looks: a 4pt target is a miss waiting to happen.
            .frame(width: 16)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        if !dragging {
                            dragging = true
                            onDragBegan()
                        }
                        onDragChanged()
                    }
                    .onEnded { _ in
                        dragging = false
                        onDragEnded()
                    }
            )
            .help("Drag toward the edge to close")
    }
}
