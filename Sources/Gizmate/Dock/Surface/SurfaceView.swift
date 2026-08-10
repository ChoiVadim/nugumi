import GizmateToolAgentCore
import SwiftUI

/// Resolves one binding from the layout tree against one row of data.
///
/// Everything a surface draws reduces to this: given a `$key` or a literal
/// and the row it is rendering, what string prints. That reduction never
/// touches SwiftUI, AppKit or the tree itself, which is what makes it the
/// one piece of this feature worth a unit test — the views around it are
/// verified by eye, not by snapshot.
enum SurfaceBinding {
    static func resolve(_ binding: ToolAgentLayoutBindingV1, in row: SurfaceRow) -> String {
        switch binding {
        case let .key(name):
            return row[name] ?? ""
        case let .literal(text):
            return text
        }
    }
}

/// Draws the layout tree a gizmo's build-time agent composed, against the
/// rows its script just printed.
///
/// Every other gizmo result finishes; a surface never does — it redraws the
/// same tree each refresh against fresh rows, which is why this view owns no
/// state of its own and takes `rows` as plain data instead.
struct SurfaceView: View {
    let layout: ToolAgentLayoutV1
    let rows: [SurfaceRow]
    /// The caption to show below the layout, or `nil` to show none —
    /// `SurfaceRefresh.caption(for:rowsAreEmpty:)` decides which, so this
    /// view only ever draws whatever string it's handed rather than
    /// deciding "stale" for itself and losing the real reason underneath.
    let stale: String?
    /// Which rows are lit. A value handed down the tree rather than read from
    /// the environment, so a click re-renders the two cards whose state changed
    /// instead of all eighty — see `SurfaceSelection`'s own comment for what
    /// that cost. Empty for every gizmo surface, which has no selection.
    var selectedIDs: Set<String> = []

    var body: some View {
        // `GeometryReader` here, not inside `OverlayScrollHost`: its document
        // view leaves height deliberately unbounded so the `NSScrollView` has
        // something to scroll (see that file), and asking either a
        // `GeometryReader` or a `LazyVGrid` to size itself against an
        // unbounded axis is exactly what collapses to zero — a `LazyVGrid`
        // needs a bound to know what to build, and `NSHostingView` never
        // re-asks a self-sizing SwiftUI subtree for its height at the width
        // Auto Layout eventually settles on, so a multi-column grid measured
        // from inside the scroll host reads the wrong width and, in this
        // one's case, the wrong height too. One level up, `SurfaceView`'s own
        // frame is fully resolved on every side by the panel that hosts it
        // (`EdgeDockController.install` pins all four edges), so measuring
        // the width there and handing it down as a plain value sidesteps the
        // chicken-and-egg entirely.
        GeometryReader { geo in
            OverlayScrollHost {
                VStack(alignment: .leading, spacing: 8) {
                    SurfaceTreeView(
                        node: layout, rows: rows, availableWidth: geo.size.width,
                        selectedIDs: selectedIDs
                    )
                    if let stale {
                        Text(stale)
                            .font(.system(size: 12))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                // Clear of the overlay scroller, which floats over the content —
                // the same trailing/bottom pad `DockNotesView` uses.
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The recursive core, deliberately with no scroll host of its own — nesting
/// a real `NSScrollView` inside another breaks wheel routing (`DESIGN.md`
/// §8), so only the outermost `SurfaceView` owns one.
private struct SurfaceTreeView: View {
    let node: ToolAgentLayoutV1
    let rows: [SurfaceRow]
    /// The width `SurfaceView`'s `GeometryReader` measured outside the scroll
    /// host — see the comment there for why a grid can't measure its own
    /// column count from inside it. Unused by `.list`, which was already
    /// eager and never had this problem.
    let availableWidth: CGFloat
    var selectedIDs: Set<String> = []

    var body: some View {
        switch node {
        case let .grid(cell, minimumWidth, empty):
            if rows.isEmpty {
                SurfaceEmptyLabel(text: empty)
            } else {
                SurfaceGrid(
                    cell: cell, rows: rows, minimumWidth: CGFloat(minimumWidth),
                    availableWidth: availableWidth, selectedIDs: selectedIDs
                )
            }

        case let .list(rowNode, empty):
            if rows.isEmpty {
                SurfaceEmptyLabel(text: empty)
            } else {
                // A hairline between cards, and nothing between bare text
                // lines. A card is a block with its own padding, so without a
                // rule two of them read as one paragraph — every stats panel
                // worth copying separates its sections. A `text` node is one
                // line of prose, and ruling prose is noise.
                let ruled = rowNode.isCard
                VStack(alignment: .leading, spacing: ruled ? 0 : 8) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if ruled, index > 0 {
                            Rectangle()
                                .fill(FlowTheme.hairline)
                                .frame(height: 1)
                        }
                        SurfaceLeafView(node: rowNode, row: row, isSelected: selectedIDs.contains(row.id))
                    }
                }
            }

        case .card, .text:
            // The candidate pipeline only ever accepts a repeater as the
            // root (`ToolAgentLayoutV1.isRepeater`), so a leaf reaching here
            // means an upstream check regressed, not real gizmo output.
            // Render it once against the first row rather than an empty
            // panel, so the bug is visible instead of silent.
            if let first = rows.first {
                SurfaceLeafView(node: node, row: first, isSelected: selectedIDs.contains(first.id))
            }
        }
    }
}

/// An eager stand-in for `LazyVGrid(columns: [.adaptive(minimum:)])`.
///
/// `LazyVGrid` needs a bounded proposal along its scroll axis to decide what
/// to build; asked from inside `OverlayScrollHost`'s document view — whose
/// height is deliberately unbounded, see that file — it collapses to zero
/// size and renders nothing, which is the bug the folder hub shipped with
/// (`SurfaceView`'s `GeometryReader` comment has the full chain). Instead of
/// self-sizing at all, this takes the column width as a plain value computed
/// once outside the scroll host and chunks rows into it eagerly — the same
/// move `NotesGrid`'s single-column dock path already made (`add5b4f`),
/// extended past one column.
private struct SurfaceGrid: View {
    let cell: ToolAgentLayoutV1
    let rows: [SurfaceRow]
    let minimumWidth: CGFloat
    let availableWidth: CGFloat
    var selectedIDs: Set<String> = []

    private static let spacing: CGFloat = 8

    /// Same formula `GridItem(.adaptive(minimum:))` uses: as many columns of
    /// at least `minimumWidth` as fit, never fewer than one. Falls back to a
    /// single column rather than dividing by a width that isn't known yet —
    /// `GeometryReader` reports a real size from its first frame here (see
    /// `SurfaceView`), but a defensive floor is cheaper than a crash if that
    /// ever stops being true.
    private var columns: Int {
        guard availableWidth > 0 else { return 1 }
        return max(1, Int((availableWidth + Self.spacing) / (minimumWidth + Self.spacing)))
    }

    private var columnWidth: CGFloat {
        guard availableWidth > 0 else { return minimumWidth }
        return max((availableWidth - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns), 0)
    }

    /// A trailing row shorter than `columns` stays left-aligned rather than
    /// stretching to fill — the same look `.adaptive` gives a partial row.
    private var chunkedRows: [[SurfaceRow]] {
        stride(from: 0, to: rows.count, by: columns).map {
            Array(rows[$0..<min($0 + columns, rows.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(Array(chunkedRows.enumerated()), id: \.offset) { _, rowChunk in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(rowChunk, id: \.id) { row in
                        // Square: the height a cell gets is the width it was
                        // already given. Every card in the grid is then the
                        // same size whatever its name wraps to, which is the
                        // one thing a grid of files has to look like.
                        SurfaceLeafView(
                            node: cell, row: row, height: columnWidth,
                            isSelected: selectedIDs.contains(row.id)
                        )
                            .frame(width: columnWidth, alignment: .topLeading)
                    }
                }
            }
        }
    }
}

/// One node rendered against one row — what a repeater's `cell`/`row`
/// reduces to: always a template, never another repeater.
///
/// `ToolAgentCandidateV1.validate` refuses a layout with a repeater anywhere
/// below its root, because `SurfaceRow` is flat — an inner repeater would
/// have no second collection to iterate. That makes the `.grid`/`.list`
/// branch below unreachable by construction, not a shape this view has to
/// make sense of.
private struct SurfaceLeafView: View {
    let node: ToolAgentLayoutV1
    let row: SurfaceRow
    /// Passed straight to `SurfaceCard` — a grid fixes it so its cells match,
    /// a list leaves it `nil`. See that property's own comment.
    var height: CGFloat? = nil
    var isSelected: Bool = false

    var body: some View {
        switch node {
        case let .card(card):
            SurfaceCard(card: card, row: row, height: height, isSelected: isSelected)

        case let .text(binding):
            Text(SurfaceBinding.resolve(binding, in: row))
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)

        case .grid, .list:
            EmptyView()
        }
    }
}

private struct SurfaceEmptyLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(FlowTheme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
    }
}
