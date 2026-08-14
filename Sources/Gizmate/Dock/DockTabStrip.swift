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
    /// the bezel.
    ///
    /// It changes one thing: whether a tab can be marked as the open one. Not
    /// size, and not position — expanding a dock must not move its icons. The
    /// peek strip is where you pick a tool, so its rhythm is the one a person
    /// has already looked at by the time the panel is open, and the rail
    /// repeating it exactly is what keeps the two reading as one control
    /// growing rather than two controls swapping.
    ///
    /// (Web nav rails group their icons at the top, and this briefly did too,
    /// on that reference. Wrong reference: those are navigation for a whole
    /// app, with nothing before them to stay continuous with.)
    var inPanel: Bool = false
    let onPick: (String) -> Void

    private var axis: Axis { edge == .top ? .horizontal : .vertical }

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
                    showsPlate: inPanel,
                    onPick: { onPick(item.id) }
                )
            }
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
    let showsPlate: Bool
    let onPick: () -> Void

    @State private var hovering = false
    @State private var pulled = false

    /// How far off the bezel a tab has to be pulled before it opens.
    ///
    /// Short, because opening is cheap and undone by moving away, unlike the
    /// 64pt `EdgeDockController.dragCloseThreshold` asks for before it throws a
    /// panel away. Pulling is the gesture the shape suggests — a tab sticking
    /// out of the edge looks like something you take hold of — and the click
    /// stays, so nobody has to learn it.
    private static let pullToOpen: CGFloat = 16

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
                    minHeight: DockGeometry.tabExtent(for: edge),
                    maxHeight: DockGeometry.tabExtent(for: edge)
                )
                .background(plate)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Simultaneous rather than instead of the button: a press that never
        // moves has to stay a press. Firing both — a pull that ends back inside
        // the tab — costs nothing, because `EdgeDockController.transition`
        // refuses a state it is already in.
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard !pulled, pull(value.translation) > Self.pullToOpen else { return }
                    pulled = true
                    onPick()
                }
                .onEnded { _ in pulled = false }
        )
        .help(item.title)
    }

    /// Travel away from the bezel, and only that. A tab dragged along its own
    /// edge, or pushed back into it, is not being opened.
    private func pull(_ translation: CGSize) -> CGFloat {
        switch edge {
        case .left: return translation.width
        case .right: return -translation.width
        // SwiftUI's y grows downward, which for the notch is inward.
        case .top: return translation.height
        }
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
    /// them is open yet, so there is nothing there for it to mark. Inset well
    /// inside the tab so it reads as a mark on the icon rather than as the tab
    /// growing a background when it opens.
    @ViewBuilder
    private var plate: some View {
        if showsPlate, isActive {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTheme.accentSoft)
                .padding(.vertical, (DockGeometry.tabExtent(for: edge) - 30) / 2)
                .padding(.horizontal, 4)
        }
    }

    private var tint: Color {
        if isActive { return FlowTheme.ink }
        return hovering ? FlowTheme.inkSecondary : FlowTheme.inkTertiary
    }
}
