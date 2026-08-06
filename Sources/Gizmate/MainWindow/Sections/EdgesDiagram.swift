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
    /// Where a side rail's first tile starts: past the top rail, then past the
    /// rail's own vertical padding. Exact now that the rails carry no caption
    /// above their tiles, but it does not have to be: a few points of slop only
    /// decides which half of a tile a landing counts as, never which rail.
    static let railContentTopInset: CGFloat = 12
    static let railContentTop: CGFloat = topRailHeight + railContentTopInset

    /// Screen-ish. Without a cap the figure stretches to whatever the window
    /// gives it and stops reading as a monitor.
    private static let aspect: CGFloat = 1.6
    private static let minWidth: CGFloat = 460
    private static let maxWidth: CGFloat = 620
    static let standHeight: CGFloat = 20
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
            // Capped, not stretched. A screen figure that grows with the window
            // stops looking like a screen and starts looking like a panel with
            // rules drawn on it, which is what the first version did in a
            // maximised window. `RingDiagram` caps its own growth for the same
            // reason.
            let width = max(
                min(geo.size.width, geo.size.height * Self.aspect, Self.maxWidth),
                Self.minWidth
            )
            let height = width / Self.aspect
            // Below `minWidth` the two rails would eat the middle, so the
            // figure stops shrinking its layout and scales instead.
            let fit = min(1, geo.size.width / width, geo.size.height / (height + Self.standHeight))
            VStack(spacing: 0) {
                figure(size: CGSize(width: width, height: height))
                    .frame(width: width, height: height)
                    // Named inside the scale, so a carried tile's location
                    // arrives in the figure's own points and needs no undoing
                    // of `fit`.
                    .coordinateSpace(name: Self.space)
                stand
            }
            .scaleEffect(fit)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// A neck and a foot under the figure. Nine lines of shapes, and they are
    /// what makes the rectangle read as a monitor at a glance instead of as
    /// four boxes that happen to touch. Everything else on this screen depends
    /// on that reading: "the left rail" only means anything once the thing it
    /// is a rail on is obviously a screen.
    private var stand: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 74, height: 14)
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 150, height: 6)
        }
        .frame(height: Self.standHeight, alignment: .top)
    }

    private func figure(size: CGSize) -> some View {
        let landing = drag.flatMap { zone(at: $0.location, in: size) }
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                topRail(size: size, landing: landing)
                HStack(spacing: 0) {
                    sideRail(.left, size: size, landing: landing)
                    centerWell(size: size, highlighted: landing == .middle)
                    sideRail(.right, size: size, landing: landing)
                }
            }
            carriedTile
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: landing)
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

    /// A rail draws nothing of its own until something is over it. The figure
    /// carries one flat fill and the middle is marked out of it by a dashed
    /// outline, so a rail is simply the part that is outside that outline, the
    /// way the bezel of a real screen is. Filling the three bands and leaving
    /// the middle dark did read as a screen, but the middle then landed as a
    /// hard black rectangle with square corners sitting inside a rounded one.
    private func band(_ highlighted: Bool) -> some View {
        Rectangle()
            .fill(highlighted ? FlowTheme.accentSoft : Color.clear)
    }

    // No "TOP" / "LEFT" / "RIGHT" / "NOT ON AN EDGE" captions. Once the figure
    // reads as a screen, a band along its top edge is the top edge, and naming
    // it is the picture repeating itself in words. The middle needed a caption
    // least of all: a tool sitting inside the screen rather than on a bezel is
    // exactly what "not on an edge" means, and `centerWell` still says so in
    // one line when there is nothing in it to make the point for it.

    /// One tile, always. The top dock has no tab strip (`EdgeDockController`
    /// expands straight to `items[0]` on hover), so a second thing up there was
    /// only ever stored, never shown. Dropping onto an occupied top rail sends
    /// whatever was there back to the middle rather than refusing the drop:
    /// a rail that quietly declines reads as broken, which is what it did.
    private func topRail(size: CGSize, landing: Zone?) -> some View {
        let occupant = tiles(on: .top).first
        return ZStack {
            if let occupant {
                tile(occupant, size: size).frame(width: Self.tileWidth)
            } else if drag != nil {
                slotOutline.frame(width: Self.tileWidth, height: Self.tileHeight)
            }
            if occupant != nil {
                HStack {
                    Spacer(minLength: 0)
                    pinToggle(.top)
                }
            }
        }
        .padding(.horizontal, Self.railPadding)
        .frame(height: Self.topRailHeight)
        .frame(maxWidth: .infinity)
        .background(band(landing == .edge(.top, 0)))
    }

    /// Top to bottom is tab order, the same order `DockTabStrip` draws.
    private func sideRail(_ edge: DockEdge, size: CGSize, landing: Zone?) -> some View {
        let items = tiles(on: edge)
        let index: Int? = {
            guard case .edge(let landed, let index) = landing, landed == edge else { return nil }
            return index
        }()
        return VStack(spacing: Self.tileSpacing) {
            ForEach(items, id: \.id) { tile($0, size: size) }
            if items.isEmpty, drag != nil {
                slotOutline.frame(height: Self.tileHeight)
            }
            Spacer(minLength: 0)
            if !items.isEmpty { pinToggle(edge) }
        }
        .padding(.horizontal, Self.railPadding)
        .padding(.vertical, 12)
        .frame(width: Self.sideRailWidth)
        .frame(maxHeight: .infinity)
        .background(band(index != nil))
        .overlay(alignment: .top) { insertionBar(at: index, count: items.count) }
    }

    /// Where the carried tool will land in this rail's order. Drawn as an
    /// overlay rather than inserted into the stack: a bar that takes part in
    /// layout pushes every tile below it down by its own height, which moves
    /// the very slots the pointer is being measured against and makes the
    /// landing flicker between two indices under a still cursor.
    @ViewBuilder
    private func insertionBar(at index: Int?, count: Int) -> some View {
        if let index, count > 0 {
            Capsule()
                .fill(FlowTheme.ink.opacity(0.8))
                .frame(height: 2)
                .padding(.horizontal, Self.railPadding)
                .offset(
                    y: Self.railContentTopInset
                        + CGFloat(index) * (Self.tileHeight + Self.tileSpacing)
                        - Self.tileSpacing / 2
                )
        }
    }

    /// How this edge's dock leaves the screen, on the edge it is about.
    ///
    /// Only for a rail with something on it: a rail with nothing parked on it
    /// has no dock to close, so a control there would configure nothing. That
    /// is also what keeps the figure clear — it carries as many of these as
    /// there are docks, which is usually one or two, not three.
    private func pinToggle(_ edge: DockEdge) -> some View {
        let pinned = dock.dismissal(on: edge) == .pinned
        return Button {
            dock.setDismissal(pinned ? .autoHide : .pinned, on: edge)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 10))
                .foregroundStyle(pinned ? FlowTheme.ink : FlowTheme.inkTertiary.opacity(0.7))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinned
            ? "Pinned. Stays open until you drag it shut or press Escape."
            : "Auto-hide. Closes when the pointer leaves.")
    }

    /// Where a tile would go, shown only while one is in flight. It used to be
    /// drawn all the time, in all three empty places at once, and three dashed
    /// rectangles asking to be filled is most of what made this page ugly:
    /// nothing was being dragged, so nothing was being asked.
    private var slotOutline: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(FlowTheme.hairline)
    }

    // MARK: - Middle

    /// The middle is not a fourth place, it is the absence of the other three,
    /// which is why landing here is `dock(_:to: nil)` and not a placement of
    /// its own. It is also the only way back off an edge: a tile carries no
    /// picker, so dragging it here is how a tool stops waiting on a bezel.
    private func centerWell(size: CGSize, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if unplaced.isEmpty {
                Text("Nothing off an edge")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ponytail: no ScrollView. A 96pt tile grid fits about a dozen
                // in the middle of the figure, and the residents are Note, the
                // folder hub and however many `.surface` gizmos exist. Wrap it
                // in one if that stops being true.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.tileWidth, maximum: Self.tileWidth),
                                       spacing: 10, alignment: .leading)],
                    spacing: 10
                ) {
                    ForEach(unplaced, id: \.id) { tile($0, size: size) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlighted ? FlowTheme.accentSoft : Color.clear)
        )
        // The dashed outline is what says "this is a place", now that the
        // middle has no fill of its own. Inset from the rails on purpose: the
        // zone `EdgesDiagram.zone` actually resolves runs all the way to them,
        // so a landing just outside the dashes still counts as the middle
        // rather than as a near miss.
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(FlowTheme.hairline)
        )
        .padding(10)
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
