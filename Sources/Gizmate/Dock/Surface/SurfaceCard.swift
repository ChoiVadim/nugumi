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
    /// The exact height every cell of a grid takes, so a two-line name can't
    /// make one card taller than its neighbours — `SurfaceGrid` passes its own
    /// column width here, which is what makes a cell square. `nil` in a list,
    /// where a row is as tall as its own content and always was.
    var height: CGFloat? = nil

    /// Only a host that installed a `SurfaceSelection` has selected cards to
    /// draw; for every gizmo surface this stays `nil` and the card looks and
    /// behaves exactly as it did before selection existed.
    @Environment(\.surfaceSelection) private var selection

    private var isSelected: Bool { selection?.ids.contains(row.id) == true }

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
                    // Two lines always in a grid, even for a short name: the
                    // label is what the flexible preview above sizes itself
                    // against, so a one-line name would otherwise hand its
                    // card a taller thumbnail than its neighbours and the row
                    // would stop lining up — the same reason the cell has a
                    // fixed height at all.
                    .lineLimit(2, reservesSpace: height != nil)
                    // The tail is the half worth keeping: a card two lines
                    // tall truncates most real filenames, and truncating the
                    // end ate the extension — which is exactly the thing a
                    // preview cannot tell you, since a video's thumbnail is a
                    // still frame and looks like a photo.
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
        // A fixed cell spends its budget on the preview, not on chrome — 8pt
        // against a ~110pt square is the difference between a thumbnail you
        // can recognise a photo in and one you can't. A list row has no such
        // trade to make and keeps the roomier 12.
        .padding(height == nil ? 12 : 8)
        .frame(maxWidth: .infinity)
        // `nil` is a no-op for `frame(height:)`, so the list path below reads
        // exactly as it did before this existed. Content stays centred in the
        // square — top-aligning it would leave a short card mostly empty.
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // Selection is a lit fill, not a border: a border on a square
                // that already sits on a hairline-free glass panel reads as a
                // second card edge, and at 110pt there is no room for both.
                .fill(isSelected ? FlowTheme.accentSoft : FlowTheme.subtleFill)
        )
        .contentShape(Rectangle())
        .modifier(SurfaceCardInteractionModifier(drag: drag, tap: tap, row: row))
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
            // What Finder itself shows for this path, real previews
            // included — a script only ever prints a path, never art, so
            // this is the one place a surface can draw something richer
            // than a glyph. See `FileThumbnail`.
            if let path = SurfaceCard.path(for: key, in: row) {
                if height == nil {
                    FileThumbnail(path: path)
                        .frame(width: 24, height: 24)
                } else {
                    // Everything the fixed-height cell has left after the
                    // label, so a wider column buys a bigger preview with no
                    // second constant to keep in step with the first.
                    FileThumbnail(path: path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

/// Decides who owns a card's mouse, and is the only place that decision is
/// made: a host that installed a `SurfaceSelection` takes all of it — one
/// AppKit view over the card doing selection, activation and a multi-file drag
/// — because an overlay that has to catch a drag catches the clicks too, and a
/// SwiftUI gesture underneath it would simply never fire. Everything else
/// keeps the SwiftUI pair it always had.
private struct SurfaceCardInteractionModifier: ViewModifier {
    let drag: ToolAgentLayoutDragV1?
    let tap: ToolAgentLayoutTapV1?
    let row: SurfaceRow
    @Environment(\.surfaceSelection) private var selection
    @Environment(\.surfaceActivate) private var activate

    @ViewBuilder
    func body(content: Content) -> some View {
        if let selection {
            content.overlay(SurfaceCardMouse(row: row, selection: selection, activate: activate))
        } else {
            content
                .modifier(SurfaceCardDragModifier(drag: drag, row: row))
                .modifier(SurfaceCardTapModifier(tap: tap, row: row))
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

/// A double-click handler the host of a surface installs, taking the place of
/// the layout's own `tap` for every card it draws.
///
/// A layout `tap` can only name an action that depends on the row — open this
/// path, reveal that one. Walking *into* a folder depends on the host's state
/// instead, so teaching `ToolAgentLayoutTapV1` a case for it would cost the
/// sidecar schema, the capability description and a parity test for the one
/// caller that isn't a gizmo at all. The environment carries it down to the
/// cards without threading a closure through four intermediate views.
private struct SurfaceActivateKey: EnvironmentKey {
    static let defaultValue: ((SurfaceRow) -> Void)? = nil
}

extension EnvironmentValues {
    var surfaceActivate: ((SurfaceRow) -> Void)? {
        get { self[SurfaceActivateKey.self] }
        set { self[SurfaceActivateKey.self] = newValue }
    }
}

/// Attaches a tap only when there is one to attach — the host's handler if it
/// installed one, the layout's otherwise. Never both: a single-click gesture
/// beside a double-click one fires on the first half of every double click,
/// so a host that browses on double-click would reveal in Finder on the way.
private struct SurfaceCardTapModifier: ViewModifier {
    let tap: ToolAgentLayoutTapV1?
    let row: SurfaceRow
    @Environment(\.surfaceActivate) private var activate

    @ViewBuilder
    func body(content: Content) -> some View {
        if let activate {
            // Finder's own gesture for "open this", and the one a card can
            // afford: a card is a drag source, and a shelf's files are picked
            // up far more often than they are opened.
            content.onTapGesture(count: 2) { activate(row) }
        } else if let tap {
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
