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
///
/// It is a full-height gutter rather than a nub floating over the content, and
/// the difference is not cosmetic. As an overlay it sat on top of whatever the
/// dock was showing: its 16pt hit area swallowed clicks meant for the panel
/// underneath, and its tooltip popped up in the middle of the text. Owning a
/// column means the content is laid out beside it instead of under it, and it
/// means the grab target is the whole length of the panel rather than 38pt of
/// it that you have to find first.
struct DockDragHandle: View {
    /// How thick the gutter is, across the panel. `EdgeDockController` insets
    /// the content by it, so the two cannot disagree about who owns those
    /// points.
    static let width: CGFloat = 14
    /// How long the visible bar is, along the panel.
    private static let barLength: CGFloat = 38

    /// Which side of the panel the handle lives on, which is the side away from
    /// the bezel: a column down the inner edge of a side dock, a bar across the
    /// bottom of the notch. It has to be told rather than assume vertical,
    /// because a notch closes upward and a horizontal capsule is what says so.
    let edge: DockEdge
    /// A click, with no drag. The gutter reads as a control, and a control you
    /// press should do the thing it is for — dragging a panel a hundred points
    /// to dismiss it is the deliberate way, not the only way.
    let onTap: () -> Void
    let onDragChanged: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let bar = Capsule()
            .fill(FlowTheme.ink.opacity(hovering || dragging ? 0.55 : 0.25))
            .frame(
                width: edge == .top ? Self.barLength : 4,
                height: edge == .top ? 4 : Self.barLength
            )
        // Draw thin, hit big — DESIGN.md §11. The ink stays 4pt because a thick
        // bar along the edge of every dock is a border; the target is the whole
        // gutter, end to end.
        return Group {
            if edge == .top {
                bar.frame(maxWidth: .infinity).frame(height: Self.width)
            } else {
                bar.frame(width: Self.width).frame(maxHeight: .infinity)
            }
        }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // A still press resolves as the tap and a moved one as the drag,
            // which `minimumDistance: 1` is what decides. The two cannot both
            // fire for one press.
            .onTapGesture(perform: onTap)
            .cursor(.openHand)
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
            .help(edge == .top ? "Click, or drag up, to close" : "Click, or drag toward the edge, to close")
    }
}
