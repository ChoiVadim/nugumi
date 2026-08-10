import SwiftUI

/// One glyph in the window's chrome, next to the traffic lights.
///
/// Quiet until hovered, because chrome that is as loud as content competes with
/// it for the eye every time you look at the screen, not only when you want it.
/// Extracted when a second such control arrived (DESIGN.md §12): two buttons
/// side by side in the same corner have to be the same button with a different
/// glyph, or the pair reads as two unrelated things that happen to be adjacent.
struct ChromeIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? FlowTheme.ink : FlowTheme.inkTertiary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? FlowTheme.subtleFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shows or hides a panel that flanks the content.
///
/// Home's gizmo rail is the only one today, and the navigation sidebar
/// deliberately is not: six short labels were trimmed to 212pt instead, which
/// buys the content more than hiding them would, without costing a decision
/// every time you look at the window. `edge` stays because the glyph has to
/// face the panel it acts on — `sidebar.leading` or `sidebar.trailing`, the
/// pair macOS itself uses — and a second collapsible panel on the left would
/// otherwise arrive with a right-facing icon.
///
/// `isOpen` is carried but unread: the glyph faces the panel, not its state,
/// the way macOS's own sidebar control does. Kept so a caller that wants to
/// draw the open and closed states differently has the answer to hand without
/// changing every call site first.
struct PanelToggleButton: View {
    let isOpen: Bool
    let edge: HorizontalEdge
    let help: String
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            symbol: edge == .leading ? "sidebar.leading" : "sidebar.trailing",
            help: help,
            action: action
        )
    }
}
