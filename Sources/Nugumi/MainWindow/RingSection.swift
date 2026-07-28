import AppKit
import SwiftUI

struct RingSection: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        RingSectionContent(layoutStore: bridge.ringLayout, toolsStore: bridge.tools)
    }
}

/// Deliberately the ring and nothing else: no list, no scroll view. The diagram
/// shrinks to whatever room the window leaves it, so the whole ring is always on
/// screen at once. Tools are created, edited, and deleted from a slot's picker.
private struct RingSectionContent: View {
    @ObservedObject var layoutStore: RingLayoutStore
    @ObservedObject var toolsStore: ToolsStore
    @EnvironmentObject var bridge: NugumiSettingsBridge

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                GeometryReader { geo in
                    let fit = min(
                        geo.size.width / RingDiagram.naturalSide,
                        geo.size.height / RingDiagram.naturalSide,
                        1
                    )
                    RingDiagram(
                        layout: layoutStore.layout,
                        tools: toolsStore.tools,
                        onPick: { bridge.ringSheet = .slot($0) },
                        onClear: { layoutStore.clear($0) }
                    )
                    .scaleEffect(fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(.horizontal, 38)
                .padding(.bottom, 38)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ring")
                    .font(FlowTheme.serif(30))
                    .foregroundStyle(FlowTheme.ink)
                Text("Click a slot to change what it does.")
                    .font(.system(size: 14))
                    .foregroundStyle(FlowTheme.inkSecondary)
            }
            Spacer(minLength: 12)
            SecondaryButton(title: "Reset to defaults") {
                layoutStore.resetToDefault()
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 38)
        .padding(.top, 38)
        .padding(.bottom, 20)
    }
}

// MARK: - Diagram

/// The ring, drawn from the same geometry the live one uses
/// (`RadialMenuLayoutPolicy`) so the preview can't drift from reality: slot *i*
/// sits where button *i* sits, and each label bubble hangs off the side it
/// hangs off on screen.
struct RingDiagram: View {
    let layout: RingLayout
    let tools: [NugumiTool]
    let onPick: (Int) -> Void
    let onClear: (Int) -> Void

    /// The live ring is drawn at 1.0; the diagram runs larger so the label
    /// bubbles have room to sit outside the circles.
    private static let scale: CGFloat = 1.4
    /// Room around the ring for the bubbles — `bubbleMaxWidth` plus the gap.
    private static let labelRoom: CGFloat = RingSlotButton.bubbleMaxWidth
        + RadialMenuLayoutPolicy.bubbleGap

    /// The size the diagram wants. The section scales it down to fit the window
    /// rather than scrolling, so this is a natural size, not a hard one.
    static var naturalSide: CGFloat {
        (RadialMenuLayoutPolicy.ringRadius * scale
            + RadialMenuLayoutPolicy.buttonDiameter * scale / 2
            + labelRoom) * 2
    }

    private var radius: CGFloat { RadialMenuLayoutPolicy.ringRadius * Self.scale }
    private var disc: CGFloat { RadialMenuLayoutPolicy.buttonDiameter * Self.scale }
    private var side: CGFloat { Self.naturalSide }

    /// AppKit offsets (y up) scaled and flipped into SwiftUI's y-down space.
    private var offsets: [CGPoint] {
        RadialMenuLayoutPolicy.buttonCenters(count: RingLayout.slotCount).map {
            CGPoint(x: $0.x * Self.scale, y: -$0.y * Self.scale)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(FlowTheme.hairline, lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2)

            hub

            ForEach(Array(offsets.enumerated()), id: \.offset) { index, center in
                RingSlotButton(
                    content: layout.slots[index],
                    tools: tools,
                    diameter: disc,
                    // `labelPlacement` reads AppKit offsets, so flip y back.
                    placement: RadialMenuLayoutPolicy.labelPlacement(
                        for: CGPoint(x: center.x, y: -center.y)
                    ),
                    action: { onPick(index) },
                    clearAction: { onClear(index) }
                )
                .offset(x: center.x, y: center.y)
            }
        }
        .frame(width: side, height: side)
    }

    /// Stand-in for the live ring's center: the bar or pet with the ✕ over it.
    private var hub: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.inkTertiary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.white.opacity(0.07)))
    }
}

enum RingSlotControlVisibility {
    static func showsClearControl(isEmpty: Bool, isHovering: Bool) -> Bool {
        !isEmpty && isHovering
    }

    static func showsClearAccessibilityAction(isEmpty: Bool) -> Bool {
        !isEmpty
    }
}

private struct RingSlotClearAccessibilityAction: ViewModifier {
    let isEmpty: Bool
    let label: String
    let clearAction: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if RingSlotControlVisibility.showsClearAccessibilityAction(isEmpty: isEmpty) {
            content.accessibilityAction(named: Text("Remove \(label) from Ring")) {
                clearAction()
            }
        } else {
            content
        }
    }
}

private struct RingSlotButton: View {
    /// Caps a long tool name so one wordy button can't blow out the diagram's
    /// width; the ring itself lets its bubbles run full length.
    static let bubbleMaxWidth: CGFloat = 132

    let content: RingSlotContent
    let tools: [NugumiTool]
    let diameter: CGFloat
    let placement: RadialMenuLabelPlacement
    let action: () -> Void
    let clearAction: () -> Void

    @State private var hovering = false

    private var tool: NugumiTool? {
        guard case .tool(let id) = content else { return nil }
        return tools.first { $0.id == id }
    }

    /// A slot pointing at a deleted tool reads as empty rather than broken.
    private var isEmpty: Bool {
        switch content {
        case .empty: return true
        case .builtIn: return false
        case .tool: return tool == nil
        }
    }

    private var label: String {
        switch content {
        case .empty: return ""
        case .builtIn(let id): return id.displayName
        case .tool: return tool?.name ?? ""
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                discBody
                    .frame(width: diameter, height: diameter)
                    .contentShape(Circle())
                    .overlay(alignment: bubbleAlignment) {
                        if !isEmpty, !label.isEmpty {
                            bubble.offset(x: bubbleOffset.x, y: bubbleOffset.y)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(isEmpty ? "Add an action" : label)
            .modifier(
                RingSlotClearAccessibilityAction(
                    isEmpty: isEmpty,
                    label: label,
                    clearAction: clearAction
                )
            )

            if RingSlotControlVisibility.showsClearControl(
                isEmpty: isEmpty,
                isHovering: hovering
            ) {
                Button(action: clearAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FlowTheme.ink)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.86)))
                        .overlay(Circle().stroke(FlowTheme.hairline, lineWidth: 1))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
                .zIndex(2)
                .help("Remove from Ring")
                .accessibilityLabel("Remove \(label) from Ring")
                .transition(.opacity)
            }
        }
        // `offset` does not participate in layout. Keep the slot centered while
        // extending this hover region to cover the clear control's 8 pt overhang.
        .padding(8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var discBody: some View {
        if isEmpty {
            ZStack {
                Circle()
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .foregroundStyle(hovering ? FlowTheme.inkSecondary : FlowTheme.hairline)
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(hovering ? FlowTheme.inkSecondary : FlowTheme.inkTertiary)
            }
        } else {
            ZStack {
                Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.10))
                Circle().strokeBorder(FlowTheme.hairline, lineWidth: 1)
                glyph
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch content {
        case .empty:
            EmptyView()
        case .builtIn(let id):
            Image(nsImage: id.icon.image(pointSize: 21))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.ink)
        case .tool:
            Image(systemName: tool?.resolvedSymbolName ?? ToolIcons.fallback)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
        }
    }

    private var bubble: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowTheme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.bubbleMaxWidth - 22)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.hairline, lineWidth: 1)
            )
    }

    /// Anchoring trick that needs no measurement: align the bubble's *far* edge
    /// to the disc's same-side edge, then push it one full diameter plus the gap
    /// outward. The bubble's near edge lands exactly `gap` off the disc.
    private var bubbleAlignment: Alignment {
        switch placement {
        case .right:       return .leading
        case .left:        return .trailing
        case .top:         return .bottom
        case .bottom:      return .top
        case .topRight:    return .bottomLeading
        case .topLeft:     return .bottomTrailing
        case .bottomRight: return .topLeading
        case .bottomLeft:  return .topTrailing
        }
    }

    private var bubbleOffset: CGPoint {
        // Cardinals: one full diameter plus the gap moves the anchored edge from
        // the disc's near side to `gap` past its far side. Diagonals reproduce
        // `RadialMenuLayoutPolicy.bubbleOrigin`'s inset, measured from the disc
        // center, then add the half-diameter the corner alignment starts at.
        let step = diameter + RadialMenuLayoutPolicy.bubbleGap
        let inset = (diameter / 2 + RadialMenuLayoutPolicy.bubbleGap) * (0.5).squareRoot()
        let diagonal = diameter / 2 + inset
        switch placement {
        case .right:       return CGPoint(x: step, y: 0)
        case .left:        return CGPoint(x: -step, y: 0)
        case .top:         return CGPoint(x: 0, y: -step)
        case .bottom:      return CGPoint(x: 0, y: step)
        case .topRight:    return CGPoint(x: diagonal, y: -diagonal)
        case .topLeft:     return CGPoint(x: -diagonal, y: -diagonal)
        case .bottomRight: return CGPoint(x: diagonal, y: diagonal)
        case .bottomLeft:  return CGPoint(x: -diagonal, y: diagonal)
        }
    }
}

/// Small status pill used by the Ring tab (in ring / unfinished / assigned).
struct RingTag: View {
    let text: String
    var accent: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(accent ? FlowTheme.accent : FlowTheme.inkTertiary)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                Capsule().fill(accent ? FlowTheme.accentSoft : Color.white.opacity(0.07))
            )
    }
}
