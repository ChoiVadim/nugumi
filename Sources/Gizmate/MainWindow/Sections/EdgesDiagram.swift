import SwiftUI

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
/// It carries its own `DragGesture` rather than `.draggable` /
/// `.dropDestination`, and that is not a style preference. SwiftUI's drag and
/// drop moves the payload through the pasteboard, which means a
/// `Transferable` needs a content type the system recognises. The type this
/// used was `UTType(exportedAs: "com.nugumi.app.edge-resident")`, which is
/// declared in no `Info.plist` — and under `swift run` there is no bundle to
/// declare it in at all. Every drag picked up and every drop silently did
/// nothing, in the old edge cards as well as the first version of this figure.
/// `RingDiagram` never had the problem because it never used the pasteboard:
/// a drag inside one view is not a transfer between two apps, and modelling it
/// as one bought a system that has to be told about the payload in a file the
/// dev build doesn't have.
///
/// The trade this makes is deliberate: hit-testing becomes ours. That is the
/// good half — `zone(at:in:leftCount:rightCount:)` is a pure function of a
/// point and a size, so `EdgesDiagramTests` can drive every landing this
/// figure has without rendering it, which nothing about the pasteboard version
/// could be.
struct EdgesDiagram: View {
    @ObservedObject var dock: DockStore
    /// Everything that can wait on an edge, in a stable order. Ids `dock` holds
    /// that aren't in here (a deleted gizmo, or a `.panel` tool whose placement
    /// only says where its answer opens) resolve to nothing and are drawn
    /// nowhere — the same thing `EdgeDockController.dockItems()` does with them.
    let residents: [DockItem]

    /// The tool currently being carried, and where the pointer has it.
    @State private var drag: Carried?

    private struct Carried {
        let id: String
        var location: CGPoint
    }

    /// One width for every tile, everywhere on the figure. The top rail used to
    /// size its single occupant to the room it had, which made the same tool
    /// visibly wider up there than on a side rail — three sizes of the same
    /// component, read as three different kinds of thing. Every other dimension
    /// here is derived from this one so they cannot drift again.
    static let tileWidth: CGFloat = 96
    static let tileHeight: CGFloat = 62
    static let tileSpacing: CGFloat = 6
    static let railPadding: CGFloat = 10
    static let sideRailWidth: CGFloat = tileWidth + railPadding * 2
    static let topRailHeight: CGFloat = 82
    /// Where a side rail's first tile starts, measured from the top of the
    /// figure: past the top rail, past the rail's own vertical padding, past
    /// its label and the gap under it. Approximate on purpose — the label's
    /// real height is whatever the system font gives it, and a few points of
    /// slop only decides which half of a tile a drop counts as, never which
    /// rail it lands on.
    static let railContentTop: CGFloat = topRailHeight + 12 + 13 + tileSpacing

    /// Screen-ish. Without a cap the figure stretches to whatever the window
    /// gives it and stops reading as a monitor.
    private static let aspect: CGFloat = 1.6
    private static let minWidth: CGFloat = 520
    private static let space = "edgesFigure"

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
            figure(size: CGSize(width: width, height: height))
                .frame(width: width, height: height)
                // Named inside the scale, so a carried tile's location arrives
                // in the figure's own points and needs no undoing of `fit`.
                .coordinateSpace(name: Self.space)
                .scaleEffect(fit)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func figure(size: CGSize) -> some View {
        let landing = drag.flatMap { zone(at: $0.location, in: size) }
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                topRail(size: size, highlighted: landing == .edge(.top, 0))
                Divider().background(FlowTheme.hairline)
                HStack(spacing: 0) {
                    sideRail(.left, size: size, highlighted: landing?.edge == .left)
                    Divider().background(FlowTheme.hairline)
                    centerWell(size: size, highlighted: landing == .middle)
                    Divider().background(FlowTheme.hairline)
                    sideRail(.right, size: size, highlighted: landing?.edge == .right)
                }
            }
            carriedTile
        }
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }

    /// The tool under the pointer, drawn above everything and hit-testing
    /// nothing — it must not become the thing the gesture thinks it is over.
    @ViewBuilder
    private var carriedTile: some View {
        if let drag, let item = byID[drag.id] {
            EdgeToolTile(item: item)
                .frame(width: Self.tileWidth)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                .position(drag.location)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Rails

    /// One tile, always. The top dock has no tab strip — `EdgeDockController`
    /// expands straight to `items[0]` on hover — so a second thing up there was
    /// only ever stored, never shown. Dropping onto an occupied top rail sends
    /// whatever was there back to the middle rather than refusing the drop:
    /// a rail that quietly declines reads as broken, which is what it did.
    private func topRail(size: CGSize, highlighted: Bool) -> some View {
        let occupant = tiles(on: .top).first
        return ZStack {
            HStack {
                railLabel(DockEdge.top.displayName)
                Spacer(minLength: 0)
            }
            Group {
                if let occupant {
                    tile(occupant, size: size)
                } else {
                    emptyHint("Drop one here")
                }
            }
            .frame(width: Self.tileWidth)
        }
        .padding(.horizontal, Self.railPadding)
        .frame(height: Self.topRailHeight)
        .frame(maxWidth: .infinity)
        .background(highlight(highlighted))
    }

    /// Top to bottom is tab order, the same order `DockTabStrip` draws.
    private func sideRail(_ edge: DockEdge, size: CGSize, highlighted: Bool) -> some View {
        let items = tiles(on: edge)
        return VStack(spacing: Self.tileSpacing) {
            railLabel(edge.displayName)
            ForEach(items, id: \.id) { tile($0, size: size) }
            if items.isEmpty { emptyHint("Drop here") }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.railPadding)
        .padding(.vertical, 12)
        .frame(width: Self.sideRailWidth)
        .frame(maxHeight: .infinity)
        .background(highlight(highlighted))
    }

    private func railLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FlowTheme.inkTertiary)
            .textCase(.uppercase)
            .kerning(0.7)
    }

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

    private func highlight(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(on ? FlowTheme.accentSoft : Color.clear)
    }

    // MARK: - Middle

    /// The middle is not a fourth place, it is the absence of the other three —
    /// which is why landing here is `dock(_:to: nil)` and not a placement of
    /// its own. It is also the only way back off an edge: a tile carries no
    /// picker, so dragging it here is how a tool stops waiting on a bezel.
    private func centerWell(size: CGSize, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            railLabel("Not on an edge")
            if unplaced.isEmpty {
                emptyHint("Drag a tool here to take it off its edge", fills: true)
            } else {
                // ponytail: no ScrollView. A 96pt tile grid fits about sixteen
                // in the middle of the figure, and the residents are Note, the
                // folder hub and however many `.surface` gizmos exist. Wrap it
                // in one if that stops being true.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth),
                                       spacing: 12, alignment: .leading)],
                    spacing: 12
                ) {
                    ForEach(unplaced, id: \.id) { tile($0, size: size) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(highlight(highlighted))
    }

    // MARK: - Dragging

    private func tile(_ item: DockItem, size: CGSize) -> some View {
        EdgeToolTile(item: item)
            .opacity(drag?.id == item.id ? 0.25 : 1)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                    .onChanged { drag = Carried(id: item.id, location: $0.location) }
                    .onEnded { _ in land(in: size) }
            )
    }

    /// Let go. The zone is resolved from the last reported location rather than
    /// `onEnded`'s own: the two agree, and reading one place means the highlight
    /// the user was looking at is exactly what decides where it lands.
    private func land(in size: CGSize) {
        guard let carried = drag else { return }
        drag = nil
        guard let zone = zone(at: carried.location, in: size) else { return }
        switch zone {
        case .middle:
            guard dock.edge(of: carried.id) != nil else { return }
            dock.dock(carried.id, to: nil)
        case .edge(.top, _):
            EdgesSection.placeOnTop(carried.id, dock: dock, residentIDs: residentIDs)
        case .edge(let edge, let index):
            // `index` counts drawn tiles; `DockStore.move` counts raw entries,
            // and a `.panel` placement on this edge sits in the raw list with
            // no tile. Naming the neighbour and letting `moveOntoResident`
            // resolve its raw position is what keeps the two in one space.
            let items = tiles(on: edge)
            if let neighbour = items[safe: index], neighbour.id != carried.id {
                EdgesSection.moveOntoResident(carried.id, target: neighbour.id, edge: edge, dock: dock)
            } else {
                EdgesSection.moveToEnd(carried.id, edge: edge, dock: dock)
            }
        }
    }

    private func zone(at point: CGPoint, in size: CGSize) -> Zone? {
        Self.zone(
            at: point,
            in: size,
            leftCount: tiles(on: .left).count,
            rightCount: tiles(on: .right).count
        )
    }
}

extension EdgesDiagram {
    /// Where a point on the figure lands. Pure, and `internal`, so
    /// `EdgesDiagramTests` can check every rail, every insertion slot and every
    /// miss without rendering anything — the whole reason hit-testing is ours
    /// rather than the pasteboard's.
    ///
    /// `index` counts *drawn* tiles on that rail, 0 meaning "before the first".
    /// The top rail always reports 0: it holds one.
    enum Zone: Equatable {
        case edge(DockEdge, Int)
        case middle

        var edge: DockEdge? {
            if case .edge(let edge, _) = self { return edge }
            return nil
        }
    }

    static func zone(at point: CGPoint, in size: CGSize, leftCount: Int, rightCount: Int) -> Zone? {
        guard size.width > 0, size.height > 0,
              (0...size.width).contains(point.x), (0...size.height).contains(point.y)
        else { return nil }
        if point.y < topRailHeight { return .edge(.top, 0) }
        if point.x < sideRailWidth { return .edge(.left, slot(at: point.y, count: leftCount)) }
        if point.x > size.width - sideRailWidth {
            return .edge(.right, slot(at: point.y, count: rightCount))
        }
        return .middle
    }

    /// Which gap between tiles a height falls in. Rounding rather than
    /// truncating is what makes the top half of a tile mean "in front of this
    /// one" and the bottom half "behind it" — truncating makes every drop land
    /// in front, so dragging something to the end of a rail is impossible.
    private static func slot(at y: CGFloat, count: Int) -> Int {
        let raw = (y - railContentTop) / (tileHeight + tileSpacing)
        return min(max(Int(raw.rounded()), 0), count)
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
        .frame(maxWidth: .infinity, minHeight: EdgesDiagram.tileHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(item.title)
    }
}
