import SwiftUI

/// Shows or hides a panel that flanks the content.
///
/// One control for both sides, because they are the same gesture and a person
/// who learns the left one should not have to learn the right. The glyph turns
/// to face the panel it acts on: `sidebar.leading` for the one on the left,
/// `sidebar.trailing` for the one on the right, which is the pair macOS itself
/// uses and the one ChatGPT's own window puts in both corners.
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
