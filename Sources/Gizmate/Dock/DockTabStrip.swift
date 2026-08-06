import SwiftUI

/// The row (top) or column (sides) of tabs a dock shows.
///
/// Never drawn for a single item — `EdgeDockController.expandedView` skips it
/// there, because one tab only names the thing you are already looking at.
///
/// Takes the edge rather than just an axis: a tab sits flush against the screen
/// bezel, and the two corners touching it must stay square. A rounded corner
/// against the bezel reads as a gap, not a curve.
struct DockTabStrip: View {
    let items: [DockItem]
    let activeID: String?
    let edge: DockEdge
    /// Whether this is the rail inside an open dock or the strip peeking out of
    /// the bezel. Two different jobs, and they want opposite things.
    ///
    /// The peek strip is a target you aim at from across the screen, so its
    /// tabs are tall (`sideTabHeight`) and read as something to pull out of the
    /// edge. The rail sits in a panel that is already open, nothing is being
    /// pulled, and the same 51pt tabs put three icons 57pt apart, reading as
    /// three unrelated things rather than one control. In the rail they are
    /// square and tight, the rhythm every reference for this uses.
    var inPanel: Bool = false
    let onPick: (String) -> Void

    private var axis: Axis { edge == .top ? .horizontal : .vertical }

    private var extent: CGFloat {
        inPanel ? DockGeometry.tabSize : DockGeometry.tabExtent(for: edge)
    }

    var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: DockGeometry.tabSpacing))
            : AnyLayout(VStackLayout(spacing: DockGeometry.tabSpacing))

        layout {
            ForEach(items, id: \.id) { item in
                DockTab(
                    item: item,
                    isActive: item.id == activeID,
                    edge: edge,
                    extent: extent,
                    showsPlate: inPanel,
                    onPick: { onPick(item.id) }
                )
            }
            // The rail fills the panel's whole side, so without this its tabs
            // sit halfway down it. Every reference groups them at the near end
            // instead: a rail is a list, and a list starts at the top.
            if inPanel { Spacer(minLength: 0) }
        }
        .padding(padding)
    }

    /// Only across the strip. Nothing on the bezel side — the tab has to touch
    /// the edge for its square corners to read as flush rather than clipped —
    /// and nothing along the long axis either, where the panel's own content
    /// insets already clear the flare.
    private var padding: EdgeInsets {
        let p = DockGeometry.stripPadding
        switch edge {
        case .top: return EdgeInsets(top: 0, leading: 0, bottom: p, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: p)
        case .right: return EdgeInsets(top: 0, leading: p, bottom: 0, trailing: 0)
        }
    }
}

/// One tab. Its own view for the hover state, which needs somewhere to live.
private struct DockTab: View {
    let item: DockItem
    let isActive: Bool
    let edge: DockEdge
    let extent: CGFloat
    let showsPlate: Bool
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            Image(nsImage: item.icon.image(pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(tint)
                // Side tabs fill whatever width the strip currently has — the
                // panel resizes with the pointer's closeness, and a fixed width
                // would leave the glass empty beside it.
                .frame(
                    maxWidth: edge == .top ? DockGeometry.tabSize : .infinity,
                    minHeight: extent,
                    maxHeight: extent
                )
                .background(plate)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
    }

    /// Which one you are looking at, said with a shape rather than a shade.
    ///
    /// It used to be tint alone, on the argument that the glass is already the
    /// surface being pressed and a plate on top of it fights the flare it sits
    /// in. That argument is right about a hover treatment and wrong about this:
    /// two greys 0.25 of alpha apart, at 15pt, on translucent glass, over an
    /// arbitrary desktop, tell nobody which tool is open. Every reference marks
    /// the active item with a filled shape behind it, and this is the one thing
    /// in the strip that has to be readable at a glance.
    ///
    /// Only in the panel: the peek strip shows a tab per resident and none of
    /// them is open yet, so there is nothing there for it to mark.
    @ViewBuilder
    private var plate: some View {
        if showsPlate, isActive {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(FlowTheme.accentSoft)
                .padding(2)
        }
    }

    private var tint: Color {
        if isActive { return FlowTheme.ink }
        return hovering ? FlowTheme.inkSecondary : FlowTheme.inkTertiary
    }
}
