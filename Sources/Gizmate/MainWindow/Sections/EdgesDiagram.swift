import SwiftUI
import UniformTypeIdentifiers

/// The Edges screen, drawn as the thing it is about: one screen, with a rail
/// along each edge a dock can hang off.
///
/// Same reasoning as `RingDiagram` — a list of edges named "Top", "Left",
/// "Right" makes you translate three words back into a picture of your own
/// monitor before you can decide anything, and the old three-cards-plus-two-
/// lists page had five places a tool could be listed for three places it could
/// actually be. Here every resident is somewhere on the figure, exactly once:
/// on a rail, or in the middle, which *is* "not on an edge".
///
/// Unlike `RingDiagram` this uses SwiftUI's own `.draggable` / `.dropDestination`
/// rather than a hand-rolled `DragGesture`. The ring needs the custom one
/// because its targets are discs on a circle and its folders spring open under
/// a carried button; here the targets are four rectangles, and the system drag
/// image already follows the cursor for free.
struct EdgesDiagram: View {
    @ObservedObject var dock: DockStore
    /// Everything that can wait on an edge, in a stable order. Ids `dock` holds
    /// that aren't in here (a deleted gizmo, or a `.panel` tool whose placement
    /// only says where its answer opens) resolve to nothing and are drawn
    /// nowhere — the same thing `EdgeDockController.dockItems()` does with them.
    let residents: [DockItem]

    /// One width for every tile, everywhere on the figure. The top rail used to
    /// size its single occupant to the room it had, which made the same tool
    /// visibly wider up there than on a side rail — three sizes of the same
    /// component, read as three different kinds of thing. Every other dimension
    /// here is derived from this one so they cannot drift again.
    private static let tileWidth: CGFloat = 96
    private static let railPadding: CGFloat = 10
    private static let sideRailWidth: CGFloat = tileWidth + railPadding * 2
    private static let topRailHeight: CGFloat = 82
    /// Screen-ish. Without a cap the figure stretches to whatever the window
    /// gives it and stops reading as a monitor.
    private static let aspect: CGFloat = 1.6
    private static let minWidth: CGFloat = 520

    private var byID: [String: DockItem] {
        Dictionary(uniqueKeysWithValues: residents.map { ($0.id, $0) })
    }

    private var residentIDs: Set<String> { Set(residents.map(\.id)) }

    private func tiles(on edge: DockEdge) -> [DockItem] {
        let byID = byID
        return dock.items(on: edge).compactMap { byID[$0] }
    }

    /// Everything with no edge — the middle of the figure. Sorted by name so
    /// the grid doesn't reshuffle itself every time a gizmo is renamed.
    private var unplaced: [DockItem] {
        let placed = Set(DockEdge.allCases.flatMap { dock.items(on: $0) })
        return residents
            .filter { !placed.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(min(geo.size.width, geo.size.height * Self.aspect), Self.minWidth)
            let height = width / Self.aspect
            // Below `minWidth` the two rails would eat the middle, so the
            // figure stops shrinking its layout and scales instead — the same
            // fit-to-window move `RingDiagram` makes, for the same reason: a
            // small window should show a small screen, not a broken one.
            let fit = min(1, geo.size.width / width, geo.size.height / height)
            figure
                .frame(width: width, height: height)
                .scaleEffect(fit)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var figure: some View {
        VStack(spacing: 0) {
            topRail
            Divider().background(FlowTheme.hairline)
            HStack(spacing: 0) {
                sideRail(.left)
                Divider().background(FlowTheme.hairline)
                centerWell
                Divider().background(FlowTheme.hairline)
                sideRail(.right)
            }
        }
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Rails

    /// One tile, always. The top dock has no tab strip — `EdgeDockController`
    /// expands straight to `items[0]` on hover — so a second thing up there was
    /// only ever stored, never shown. Dropping onto an occupied top rail sends
    /// whatever was there back to the middle rather than refusing the drop:
    /// a rail that quietly declines reads as broken, which is what it did.
    private var topRail: some View {
        let occupant = tiles(on: .top).first
        return ZStack {
            HStack {
                railLabel(DockEdge.top.displayName)
                Spacer(minLength: 0)
            }
            Group {
                if let occupant {
                    EdgeToolTile(item: occupant)
                } else {
                    emptyHint("Drop one here")
                }
            }
            .frame(width: Self.tileWidth)
        }
        .padding(.horizontal, Self.railPadding)
        .frame(height: Self.topRailHeight)
        .frame(maxWidth: .infinity)
        .dropTarget { EdgesSection.placeOnTop($0, dock: dock, residentIDs: residentIDs) }
    }

    /// Top to bottom is tab order, the same order `DockTabStrip` draws. A drop
    /// onto a tile lands in front of it; a drop anywhere else in the rail lands
    /// at the end.
    private func sideRail(_ edge: DockEdge) -> some View {
        let items = tiles(on: edge)
        return VStack(spacing: 6) {
            railLabel(edge.displayName)
            ForEach(items, id: \.id) { item in
                EdgeToolTile(item: item)
                    .dropTarget {
                        EdgesSection.moveOntoResident($0, target: item.id, edge: edge, dock: dock)
                    }
            }
            if items.isEmpty { emptyHint("Drop here") }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.railPadding)
        .padding(.vertical, 12)
        .frame(width: Self.sideRailWidth)
        .frame(maxHeight: .infinity)
        .dropTarget { EdgesSection.moveToEnd($0, edge: edge, dock: dock) }
    }

    private func railLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FlowTheme.inkTertiary)
            .textCase(.uppercase)
            .kerning(0.7)
    }

    /// `fills` is what makes the middle's version a real target rather than a
    /// caption: a dashed well that grows to the whole empty area is both the
    /// affordance and the thing the pointer has to be over to let go.
    private func emptyHint(_ text: String, fills: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(FlowTheme.inkTertiary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(FlowTheme.hairline)
            )
    }

    // MARK: - Middle

    /// The middle is not a fourth place, it is the absence of the other three —
    /// which is why dropping here is `dock(_:to: nil)` and not a placement of
    /// its own. It is also the only way back off an edge: rail tiles carry no
    /// picker, because a picker would fight the drag gesture for the same click.
    private var centerWell: some View {
        VStack(alignment: .leading, spacing: 10) {
            railLabel("Not on an edge")
            wellBody
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropTarget { dock.dock($0, to: nil) }
    }

    /// Both branches fill the height on purpose. An empty middle used to be one
    /// line of text with a `Spacer` under it, and a `.frame` with nothing drawn
    /// in it is not somewhere a drop can land — the affordance and the hit
    /// target are the same object here, so there has to be one.
    @ViewBuilder
    private var wellBody: some View {
        if unplaced.isEmpty {
            emptyHint("Drag a tool here to take it off its edge", fills: true)
        } else {
            // ponytail: no ScrollView. A 96pt tile grid fits about sixteen in
            // the middle of the figure, and the residents are Note, the folder
            // hub and however many `.surface` gizmos exist. Wrap it in one if
            // that stops being true — but a ScrollView here also swallows the
            // drop this well exists for, so it needs its own `dropTarget` on
            // the scrolled content when it arrives.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth),
                                   spacing: 12, alignment: .leading)],
                spacing: 12
            ) {
                ForEach(unplaced, id: \.id) { EdgeToolTile(item: $0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Tiles

/// One draggable tool on the figure — one size, wherever it sits. It had a
/// `.rail` and a `.well` variant briefly, which DESIGN.md §12 would have
/// allowed if the two had a real difference to encode; they didn't, and the
/// only thing the parameter bought was the same tool looking bigger on the top
/// rail than on a side one, as though it were a different kind of thing.
private struct EdgeToolTile: View {
    let item: DockItem

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: item.icon.image(pointSize: 19))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.ink)
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FlowTheme.inkSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        // Uniform height as well as width: a one-word name and a two-word one
        // otherwise make neighbouring tiles different sizes down a rail.
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .draggable(EdgeResidentDrag(id: item.id))
        .help(item.title)
    }
}

// MARK: - Drag and drop

/// What a tile hands a drop target: just its dock id. A dedicated type rather
/// than bare `String` so a stray text drag from another app can't land here and
/// read as though it named a real one.
private struct EdgeResidentDrag: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .gizmateEdgeResident)
    }
}

private extension UTType {
    static let gizmateEdgeResident = UTType(exportedAs: "com.nugumi.app.edge-resident")
}

private extension View {
    /// A drop target that lights up while something is over it. Every target on
    /// the figure wants the same two behaviours, and `dropDestination`'s two
    /// trailing closures plus the `@State` for the highlight is four lines each
    /// at five call sites.
    func dropTarget(_ handle: @escaping (String) -> Void) -> some View {
        modifier(EdgeDropTarget(handle: handle))
    }
}

private struct EdgeDropTarget: ViewModifier {
    let handle: (String) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isTargeted ? FlowTheme.accentSoft : Color.clear)
            )
            // Every target on the figure is mostly empty space inside a frame,
            // and empty space inside a frame is not somewhere a drop lands.
            .contentShape(Rectangle())
            .dropDestination(for: EdgeResidentDrag.self) { drags, _ in
                guard let dragged = drags.first else { return false }
                handle(dragged.id)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
