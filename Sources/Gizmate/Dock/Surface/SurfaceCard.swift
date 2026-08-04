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
            if let icon {
                iconView(icon)
            }
            VStack(spacing: 4) {
                Text(resolvedTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkSecondary)
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

    @ViewBuilder
    private func iconView(_ icon: ToolAgentLayoutIconV1) -> some View {
        switch icon {
        case let .file(key):
            // The icon Finder itself shows for this path, thumbnails
            // included — a script only ever prints a path, never art, so
            // this is the one place a surface can draw something richer
            // than a glyph.
            let path = row[key] ?? ""
            if !path.isEmpty {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 24, height: 24)
            }
        case let .symbol(name):
            // Routed through the ring's own icon catalog rather than SF
            // Symbols directly, so a surface cannot name art the ring
            // doesn't already have.
            Image(nsImage: RingIconKind.phosphor(name).image(pointSize: 20))
                .resizable()
                .foregroundStyle(FlowTheme.ink)
                .frame(width: 20, height: 20)
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
            content.onDrag { provider(for: drag) }
        } else {
            content
        }
    }

    private func provider(for drag: ToolAgentLayoutDragV1) -> NSItemProvider {
        switch drag {
        case let .file(key):
            let path = row[key] ?? ""
            // A real file URL, so the drop lands as a file in Finder, Slack
            // or anything else — this is the whole point of a surface, and
            // it is native-only: no web view can hand a real file to another
            // app. `?? NSItemProvider()` covers the stale-row case where the
            // key no longer resolves to anything on disk.
            return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
        case let .text(key):
            let text = row[key] ?? ""
            return NSItemProvider(object: text as NSString)
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
        let path = row[tap.key] ?? ""
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        switch tap {
        case .open: NSWorkspace.shared.open(url)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
