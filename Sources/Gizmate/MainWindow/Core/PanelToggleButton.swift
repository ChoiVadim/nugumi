import SwiftUI

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
/// Quiet until hovered. It sits in the window's chrome, next to the traffic
/// lights, and chrome that is as loud as content competes with it for the eye
/// every time you look at the screen — not only when you want this.
struct PanelToggleButton: View {
    let isOpen: Bool
    let edge: HorizontalEdge
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: edge == .leading ? "sidebar.leading" : "sidebar.trailing")
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
