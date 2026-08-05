import AppKit
import GizmateToolAgentCore
import SwiftUI

/// One leaf of a surface: an icon over a title over an optional subtitle —
/// the shape of a file the user can drag out of the panel.
///
/// Reused for both a grid's cell and a list's row (`DESIGN.md` §12): the two
/// only ever differ in how their repeater arranges cards, never in what a
/// card looks like, so there is one card type rather than a grid variant and
/// a list variant drifting apart from each other.
struct SurfaceCard: View {
    let title: ToolAgentLayoutBindingV1
    let subtitle: ToolAgentLayoutBindingV1?
    let icon: ToolAgentLayoutIconV1?
    let drag: ToolAgentLayoutDragV1?
    let tap: ToolAgentLayoutTapV1?
    let row: SurfaceRow

    private var resolvedTitle: String { SurfaceBinding.resolve(title, in: row) }

    /// `nil` both when the layout never asked for a subtitle and when the key
    /// it named is missing from this row — either way there is nothing to
    /// show, and the card loses the line, not itself.
    private var resolvedSubtitle: String? {
        guard let subtitle else { return nil }
        let value = SurfaceBinding.resolve(subtitle, in: row)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(spacing: 8) {
            // Gated on whether the icon will actually draw something, not
            // just on whether one was declared: an `if` with no `else`
            // still occupies a slot in this VStack even when it renders
            // nothing, so a `.file` icon whose key is missing left an 8pt
            // gap above the title with no icon in it.
            if let icon, hasVisibleIcon(icon) {
                iconView(icon)
            }
            // Both lines sit at Caption (12px, DESIGN.md §3) — there is no
            // 11px regular level, only Micro (11px, semibold, for monospaced
            // section labels), which a file's subtitle isn't. Hierarchy
            // comes from weight and colour instead, per §3's own rule: "Use
            // medium and semibold for hierarchy instead of larger sizes."
            VStack(spacing: 4) {
                Text(resolvedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .contentShape(Rectangle())
        .modifier(SurfaceCardDragModifier(drag: drag, row: row))
        .modifier(SurfaceCardTapModifier(tap: tap, row: row))
    }

    /// Whether `iconView` will draw anything for this icon against this row
    /// — the question `body` needs answered before it decides whether to
    /// give the icon a slot at all. A `.symbol` always draws something:
    /// `CandidateValidation` rejects a name that doesn't resolve before the
    /// gizmo is ever saved, and `iconView` falls back to a known-good glyph
    /// regardless. A `.file` icon draws only when its row actually has one.
    private func hasVisibleIcon(_ icon: ToolAgentLayoutIconV1) -> Bool {
        switch icon {
        case let .file(key): return SurfaceCard.path(for: key, in: row) != nil
        case .symbol: return true
        }
    }

    @ViewBuilder
    private func iconView(_ icon: ToolAgentLayoutIconV1) -> some View {
        switch icon {
        case let .file(key):
            // The icon Finder itself shows for this path, thumbnails
            // included — a script only ever prints a path, never art, so
            // this is the one place a surface can draw something richer
            // than a glyph.
            if let path = SurfaceCard.path(for: key, in: row) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 24, height: 24)
            }
        case let .symbol(name):
            // SF Symbols — the same catalog `GizmateTool.resolvedSymbolName`
            // draws a gizmo's own icon from, not the ring's bundled
            // Phosphor set: none of those five glyphs is a plausible row
            // icon, and the model is never told their names. Resolved
            // through `ToolIcons` rather than trusting `name` outright:
            // `CandidateValidation` already refuses an unresolvable name at
            // build time, but a layout loaded back off disk after an OS
            // change could still name one that stopped resolving, and this
            // is the difference between a fallback glyph and a blank one.
            Image(nsImage: RingIconKind.symbol(ToolIcons.resolved(name)).image(pointSize: 20))
                .resizable()
                .foregroundStyle(FlowTheme.ink)
                .frame(width: 20, height: 20)
        }
    }

    /// A row's value for `key`, or `nil` when the key is missing or empty —
    /// the one place "there is no path here" is decided, so the icon, both
    /// drags and the tap all treat a stale or absent row the same way.
    /// Getting this wrong is not cosmetic for a `.file` binding:
    /// `URL(fileURLWithPath: "")` resolves to the process's working
    /// directory, so treating `""` as a real path the way `row[key] ?? ""`
    /// used to hands a drag the volume root instead of doing nothing. A
    /// `.text` binding has no such hazard, but the same missing-key case
    /// still shouldn't hand out a drag that looks live and drops an empty
    /// string.
    static func path(for key: String, in row: SurfaceRow) -> String? {
        guard let value = row[key], !value.isEmpty else { return nil }
        return value
    }

    /// The drag payload for one row, or a bare, inert provider when the
    /// bound key is missing or empty. Internal rather than folded into
    /// `SurfaceCardDragModifier` so `SurfaceCardTests` can pin the inert
    /// case directly, the same reasoning `SurfaceRefresh.caption` was
    /// pulled out for.
    static func dragProvider(for drag: ToolAgentLayoutDragV1, in row: SurfaceRow) -> NSItemProvider {
        switch drag {
        case let .file(key):
            // A real file URL, so the drop lands as a file in Finder, Slack
            // or anything else — this is the whole point of a surface, and
            // it is native-only: no web view can hand a real file to another
            // app. A missing or empty key returns a bare, inert provider
            // rather than reach `URL(fileURLWithPath:)` at all — that
            // initialiser turns "" into the process's working directory,
            // which `NSItemProvider(contentsOf:)` happily hands to whatever
            // the card was dropped on.
            guard let path = path(for: key, in: row) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
        case let .text(key):
            // Same rule as the `.file` case above: a missing or empty key
            // returns a bare, inert provider rather than one that looks
            // live and drops an empty string.
            guard let text = path(for: key, in: row) else { return NSItemProvider() }
            return NSItemProvider(object: text as NSString)
        }
    }
}

/// Attaches `.onDrag` only when the layout declared one — whether the drag
/// actually produces a file is a per-row concern handled inside the closure.
private struct SurfaceCardDragModifier: ViewModifier {
    let drag: ToolAgentLayoutDragV1?
    let row: SurfaceRow

    func body(content: Content) -> some View {
        if let drag {
            content.onDrag { SurfaceCard.dragProvider(for: drag, in: row) }
        } else {
            content
        }
    }
}

/// Attaches `.onTapGesture` only when the layout declared one.
private struct SurfaceCardTapModifier: ViewModifier {
    let tap: ToolAgentLayoutTapV1?
    let row: SurfaceRow

    func body(content: Content) -> some View {
        if let tap {
            content.onTapGesture { perform(tap) }
        } else {
            content
        }
    }

    private func perform(_ tap: ToolAgentLayoutTapV1) {
        guard let path = SurfaceCard.path(for: tap.key, in: row) else { return }
        let url = URL(fileURLWithPath: path)
        switch tap {
        case .open: NSWorkspace.shared.open(url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
