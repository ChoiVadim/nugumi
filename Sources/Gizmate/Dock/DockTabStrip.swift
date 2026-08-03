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
    let onPick: (String) -> Void

    private var axis: Axis { edge == .top ? .horizontal : .vertical }

    var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: DockGeometry.tabSpacing))
            : AnyLayout(VStackLayout(spacing: DockGeometry.tabSpacing))

        layout {
            ForEach(items, id: \.id) { item in
                Button { onPick(item.id) } label: {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.id == activeID ? FlowTheme.ink : FlowTheme.inkSecondary)
                        .frame(width: DockGeometry.tabSize, height: DockGeometry.tabSize)
                        .background(
                            UnevenRoundedRectangle(cornerRadii: tabCornerRadii, style: .continuous)
                                .fill(item.id == activeID ? FlowTheme.raised : FlowTheme.subtleFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
            }
        }
        .padding(padding)
    }

    /// Square on the side facing the bezel, rounded on the other three.
    private var tabCornerRadii: RectangleCornerRadii {
        let r = DockGeometry.tabCornerRadius
        switch edge {
        case .top:
            return RectangleCornerRadii(
                topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0
            )
        case .left:
            return RectangleCornerRadii(
                topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r
            )
        case .right:
            return RectangleCornerRadii(
                topLeading: r, bottomLeading: r, bottomTrailing: 0, topTrailing: 0
            )
        }
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
