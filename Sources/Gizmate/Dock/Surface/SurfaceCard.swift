import AppKit
import GizmateToolAgentCore
import SwiftUI

/// One leaf of a surface: an icon, a title, and whatever else the layout asked
/// for — the shape of a file the user can drag out of the panel, or of one
/// reading on a stats strip.
///
/// One card type for both a grid's cell and a list's row (`DESIGN.md` §12),
/// with the two arrangements differing only in the axis they stack on. A grid
/// cell is a square (§13) and puts the icon above centred text, because a
/// square's width is the scarce thing. A list row is as wide as the panel and
/// as tall as it needs, so it puts the icon beside left-aligned text, which is
/// what every list on this platform looks like — and it is the only one of the
/// two with room for detail lines, a bar or a graph.
struct SurfaceCard: View {
    let card: ToolAgentLayoutCardV1
    let row: SurfaceRow
    /// The exact height every cell of a grid takes, so a two-line name can't
    /// make one card taller than its neighbours — `SurfaceGrid` passes its own
    /// column width here, which is what makes a cell square. `nil` in a list,
    /// where a row is as tall as its own content and always was.
    var height: CGFloat? = nil
    /// Handed down rather than read from the environment. An environment value
    /// invalidates every view that reads it, so selection living there meant
    /// one click rebuilt all eighty cards — see `SurfaceSelection`'s comment.
    /// Always false for a gizmo surface, which has no selection.
    var isSelected: Bool = false

    private var resolvedTitle: String { SurfaceBinding.resolve(card.title, in: row) }

    /// `nil` both when the layout never asked for a subtitle and when the key
    /// it named is missing from this row — either way there is nothing to
    /// show, and the card loses the line, not itself.
    private var resolvedSubtitle: String? {
        guard let subtitle = card.subtitle else { return nil }
        let value = SurfaceBinding.resolve(subtitle, in: row)
        return value.isEmpty ? nil : value
    }

    /// The detail lines this row actually has something to say on, in the order
    /// the layout gave. A line whose key is missing disappears rather than
    /// leaving a blank — the same rule the subtitle has always followed, and
    /// the reason a stats panel can list six possible readings and draw the
    /// four a particular machine reports.
    private var resolvedDetails: [String] {
        card.details
            .map { SurfaceBinding.resolve($0, in: row) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Group {
            if height == nil {
                listBody
            } else {
                gridBody
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
                //
                // Unselected, only a grid cell carries a fill. A list rules
                // its rows apart with a hairline, and a fill under every row
                // as well draws a second edge just inside the first — the
                // "border around a border" the question bubble avoids for the
                // same reason.
                .fill(fill)
        )
        // A border, not just a brighter fill. Selected and unselected were two
        // whites a tenth of an alpha apart, on a translucent panel, over an
        // arbitrary desktop — the same "shade, not shape" mistake the dock's
        // tab strip made, and unreadable for the same reason. Gizmate has no
        // colour accent to reach for (DESIGN.md §2), so the shape does the
        // work: an outline is present or absent, which no wallpaper can wash
        // out halfway.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(FlowTheme.ink.opacity(isSelected ? 0.75 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .modifier(SurfaceCardInteractionModifier(drag: card.drag, tap: card.tap, row: row))
    }

    private var fill: Color {
        if isSelected { return FlowTheme.accentSoft }
        return height == nil ? .clear : FlowTheme.subtleFill
    }

    /// A square cell: icon above, text centred under it. Detail lines, a bar
    /// and a graph cannot reach here — `SurfaceLayoutCheck` refuses a grid
    /// whose cell asks for them, because this cell's height is its column's
    /// width and there is nowhere for them to go.
    private var gridBody: some View {
        VStack(spacing: 8) {
            // Gated on whether the icon will actually draw something, not
            // just on whether one was declared: an `if` with no `else`
            // still occupies a slot in this VStack even when it renders
            // nothing, so a `.file` icon whose key is missing left an 8pt
            // gap above the title with no icon in it.
            if let icon = card.icon, hasVisibleIcon(icon) {
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
                    .lineLimit(2, reservesSpace: true)
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
    }

    /// A row across the panel: icon beside the text, everything left-aligned.
    ///
    /// The icon is centred against the whole text block, the way every stats
    /// strip on this platform draws its sections (iStat Menus is the shape
    /// being copied): a reading is a block, and its glyph is the block's
    /// emblem, not its first line's bullet. This reverses an earlier top-pin —
    /// that call was made when rows were one line tall, where the two
    /// alignments draw identically, so nothing that argued for it is lost.
    /// The 30pt slot is fixed so the text column starts at the same x in
    /// every row whatever each glyph's own aspect is.
    private var listBody: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = card.icon, hasVisibleIcon(icon) {
                iconView(icon)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(resolvedTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(1)
                }
                ForEach(Array(resolvedDetails.enumerated()), id: \.offset) { _, detail in
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .lineLimit(1)
                }
                if let fraction = meterFraction {
                    SurfaceMeterBar(fraction: fraction)
                        .padding(.top, 2)
                }
                if let series = chartSeries {
                    SurfaceSparkline(values: series)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// `nil` when the layout asked for no bar, when this row has no value for
    /// it, or when the value isn't one `SurfaceMeter` accepts. The last case
    /// is refused at build time against a real run, so reaching it means a
    /// script that printed a good value then printed a bad one later — and a
    /// missing bar is a better answer than a bar showing a number nobody can
    /// defend.
    private var meterFraction: Double? {
        guard let key = card.meter, let value = SurfaceCard.path(for: key, in: row) else {
            return nil
        }
        return SurfaceMeter.fraction(from: value)
    }

    private var chartSeries: [Double]? {
        guard let key = card.chart, let value = SurfaceCard.path(for: key, in: row) else {
            return nil
        }
        return SurfaceSeries.values(from: value)
    }

    /// Whether `iconView` will draw anything for this icon against this row
    /// — the question `body` needs answered before it decides whether to
    /// give the icon a slot at all. A `.symbol` always draws something:
    /// `CandidateValidation` rejects a name that doesn't resolve before the
    /// gizmo is ever saved, and `iconView` falls back to a known-good glyph
    /// regardless. A `.file` icon draws only when its row actually has one.
    private func hasVisibleIcon(_ icon: ToolAgentLayoutIconV1) -> Bool {
        switch icon {
        case let .file(key), let .symbolKey(key): return SurfaceCard.path(for: key, in: row) != nil
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
            symbolIcon(name)
        case let .symbolKey(key):
            // The glyph this particular row asked for, so one surface can show
            // a CPU card beside a disk card. `ToolIcons.resolved` is doing real
            // work here rather than standing by as it does above: this name is
            // data, so no build-time check ever saw the value a run prints
            // today, and the fallback glyph is what a script's typo costs.
            if let name = SurfaceCard.path(for: key, in: row) {
                symbolIcon(name)
            }
        }
    }

    /// SF Symbols — the same catalog `GizmateTool.resolvedSymbolName` draws a
    /// gizmo's own icon from, not the ring's bundled Phosphor set: none of
    /// those five glyphs is a plausible row icon, and the model is never told
    /// their names. Resolved through `ToolIcons` rather than trusting `name`
    /// outright: `CandidateValidation` already refuses an unresolvable name at
    /// build time, but a layout loaded back off disk after an OS change could
    /// still name one that stopped resolving, and this is the difference
    /// between a fallback glyph and a blank one.
    private func symbolIcon(_ name: String) -> some View {
        // A list row's glyph is the section's emblem and draws at 28pt with a
        // light stroke, the outline look the reference stats strips use; a
        // grid cell keeps the 20pt it always had — its square spends the room
        // on the preview, not the glyph.
        let size: CGFloat = height == nil ? 28 : 20
        // `scaledToFit`, not a bare `resizable` into a square frame: SF glyphs
        // are not square — a battery is wide, a drive is squat — and forcing
        // the aspect squashed exactly the glyphs this size was bought for.
        return Image(
            nsImage: RingIconKind.symbol(ToolIcons.resolved(name))
                .image(pointSize: size, weight: height == nil ? .light : .regular)
        )
        .resizable()
        .scaledToFit()
        .foregroundStyle(FlowTheme.ink)
        .frame(width: size, height: size)
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
            content.onTapGesture(count: 2) { activate(row) }.cursor(.openHand)
        } else if let tap {
            content.onTapGesture { perform(tap) }.cursor(.pointingHand)
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
