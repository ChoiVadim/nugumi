import SwiftUI

struct MenuFieldLabel: View {
    let text: String
    var body: some View {
        // No chevron here — the Menu's own native disclosure indicator sits to
        // the right. Drawing our own too produced a duplicate arrow.
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowTheme.ink)
            .lineLimit(1)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

/// A read-only language field that mirrors `MenuFieldLabel`'s shape but with no
/// disclosure chevron and dimmed ink, signalling a fixed value rather than a picker.
struct ReadOnlyField: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowTheme.inkSecondary)
            .lineLimit(1)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

struct KeyCap: View {
    let text: String
    /// Dimmed style for a fixed, non-rebindable secondary cap (e.g. the Ask
    /// Gizmate ⌃⌥A alias shown next to its configurable shortcut).
    var muted: Bool = false
    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(muted ? FlowTheme.inkSecondary : FlowTheme.ink)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .frame(minWidth: 56)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(muted ? 0.04 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

struct SecondaryButton: View {
    let title: String
    var destructive: Bool = false
    /// Set to align a column of buttons (e.g. Help rows) to one width.
    var minWidth: CGFloat?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(destructive ? Color(red: 1.0, green: 0.62, blue: 0.62) : Color.white)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .frame(minWidth: minWidth)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(destructive ? Color.red.opacity(0.18) : Color.white.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Flow-style underlined text tabs: quiet labels on a hairline baseline, the
/// active one bright with a 2pt indicator.
struct FlowTabBar: View {
    let tabs: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 24) {
            ForEach(tabs.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    VStack(spacing: 8) {
                        Text(tabs[index])
                            .font(.system(size: 13.5, weight: selection == index ? .semibold : .regular))
                            .foregroundStyle(selection == index ? FlowTheme.ink : FlowTheme.inkSecondary)
                        Rectangle()
                            .fill(selection == index ? Color.white : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowTheme.hairline)
                .frame(height: 1)
        }
    }
}

/// Reset, kept to a disc so it doesn't compete with the heading. The label is
/// laid out at full width the whole time and only fades in on hover, so the
/// heading beside it never re-wraps as the pointer crosses in. It is deliberately
/// outside the button: an invisible click target that wipes state is a trap.
/// A quiet disc with a glyph, whose label fades in on hover. Named for its
/// first use; `symbol` and `label` make it the generic header disc, which is
/// what Notes' "Add note" uses.
struct ResetDiscButton: View {
    var symbol: String = "arrow.counterclockwise"
    var label: String = "Reset to defaults"
    var accessibilityTitle: String = "Reset to defaults"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hovering ? FlowTheme.ink : FlowTheme.inkSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? FlowTheme.raised : FlowTheme.subtleFill))
                .overlay(Circle().stroke(FlowTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .accessibilityLabel(accessibilityTitle)
        // Drawn beside the disc, never laid out with it. An inline label keeps
        // its width at zero opacity, which is invisible when the disc stands
        // alone at a header's edge but shoves neighbouring discs apart the
        // moment there are two. The offset clears the 30pt disc plus 8pt of gap.
        .overlay(alignment: .trailing) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
                .offset(x: -38)
        }
    }
}

struct RowIconButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? FlowTheme.ink : FlowTheme.inkSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
