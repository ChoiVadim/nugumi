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
    let isStale: Bool

    var body: some View {
        OverlayScrollHost {
            VStack(alignment: .leading, spacing: 8) {
                SurfaceTreeView(node: layout, rows: rows)
                if isStale {
                    Text("Couldn't refresh — showing what was here last.")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The recursive core, deliberately with no scroll host of its own — nesting
/// a real `NSScrollView` inside another breaks wheel routing (`DESIGN.md`
/// §8), so only the outermost `SurfaceView` owns one.
private struct SurfaceTreeView: View {
    let node: ToolAgentLayoutV1
    let rows: [SurfaceRow]

    var body: some View {
        switch node {
        case let .grid(cell, minimumWidth, empty):
            if rows.isEmpty {
                SurfaceEmptyLabel(text: empty)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: CGFloat(minimumWidth)), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(rows, id: \.id) { row in
                        SurfaceLeafView(node: cell, row: row)
                    }
                }
            }

        case let .list(rowNode, empty):
            if rows.isEmpty {
                SurfaceEmptyLabel(text: empty)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.id) { row in
                        SurfaceLeafView(node: rowNode, row: row)
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
                SurfaceLeafView(node: node, row: first)
            }
        }
    }
}

/// One node rendered against one row — what a repeater's `cell`/`row`
/// reduces to, and what a nested repeater reduces to as well.
///
/// `SurfaceRow` is flat, so a repeater nested inside another repeater's cell
/// has no second collection to iterate — there is no "child rows of this
/// row." It repeats over just the row it was handed, collapsing to a single
/// iteration. `maximumDepth = 3` allows the model to write this shape, but
/// no script's actual output motivates it.
private struct SurfaceLeafView: View {
    let node: ToolAgentLayoutV1
    let row: SurfaceRow

    var body: some View {
        switch node {
        case let .card(title, subtitle, icon, drag, tap):
            SurfaceCard(title: title, subtitle: subtitle, icon: icon, drag: drag, tap: tap, row: row)

        case let .text(binding):
            Text(SurfaceBinding.resolve(binding, in: row))
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)

        case .grid, .list:
            SurfaceTreeView(node: node, rows: [row])
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
