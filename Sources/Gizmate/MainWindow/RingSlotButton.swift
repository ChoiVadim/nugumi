import SwiftUI

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

/// One position in the ring diagram: the disc, its label bubble, the ✕ that
/// empties it, and the press that either opens the picker or carries the disc
/// off to another slot.
struct RingSlotButton: View {
    /// Caps a long tool name so one wordy button can't blow out the diagram's
    /// width; the ring itself lets its bubbles run full length.
    static let bubbleMaxWidth: CGFloat = 132
    /// One line of 12pt text plus the bubble's vertical padding — what a bubble
    /// above or below a button actually costs in height.
    static let bubbleHeight: CGFloat = 28

    let content: RingSlotContent
    let tools: [GizmateTool]
    let folders: [RingFolder]
    let diameter: CGFloat
    let placement: RadialMenuLabelPlacement
    /// False for rings sitting behind an open orbit — their bubbles would
    /// collide with the ones in front.
    var showsLabel: Bool = true
    let action: () -> Void
    let clearAction: () -> Void
    /// Lets the diagram fan a folder's orbit out while the pointer is here.
    var onHover: (Bool) -> Void = { _ in }
    /// Non-nil for a disc that may be carried elsewhere — empty slots have
    /// nothing to pick up. Reports how far the press has travelled, in screen
    /// points.
    var onDragChanged: ((CGSize) -> Void)? = nil
    /// The press ended after travelling: the diagram drops the disc wherever it
    /// currently is.
    var onDragEnded: (() -> Void)? = nil
    /// This is the disc being carried right now. It rides above the diagram and
    /// drops its bubble, which would otherwise fly around with it.
    var isDragging: Bool = false
    /// A carried disc would land here if it were let go now.
    var isDropTarget: Bool = false

    @State private var hovering = false
    /// The press has already travelled far enough to be a drag, so letting go
    /// drops the disc instead of opening the picker.
    @State private var carrying = false

    private var tool: GizmateTool? {
        guard case .tool(let id) = content else { return nil }
        return tools.first { $0.id == id }
    }

    private var folder: RingFolder? {
        guard case .folder(let id) = content else { return nil }
        return folders.first { $0.id == id }
    }

    /// A slot pointing at a deleted tool reads as empty rather than broken.
    private var isEmpty: Bool {
        switch content {
        case .empty: return true
        case .builtIn: return false
        case .tool: return tool == nil
        case .folder: return folder == nil
        }
    }

    private var label: String {
        switch content {
        case .empty: return ""
        case .builtIn(let id): return id.displayName
        case .tool: return tool?.name ?? ""
        case .folder: return folder?.name ?? ""
        }
    }

    /// How many of the folder's own slots are filled — shown as a badge so a
    /// folder reads as a container without having to open it.
    private var folderCount: Int {
        folder?.layout.slots.filter { $0 != .empty }.count ?? 0
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            disc

            if RingSlotControlVisibility.showsClearControl(
                isEmpty: isEmpty,
                isHovering: hovering && !isDragging
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
        .onHover {
            hovering = $0
            onHover($0)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var disc: some View {
        discBody
            .frame(width: diameter, height: diameter)
            .overlay {
                if isDropTarget {
                    Circle()
                        .strokeBorder(FlowTheme.accent, lineWidth: 2)
                        .padding(-4)
                }
            }
            .scaleEffect(isDragging ? 1.06 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 10, y: 4)
            .contentShape(Circle())
            .overlay(alignment: bubbleAlignment) {
                if showsLabel, !isDragging, !isEmpty, !label.isEmpty {
                    bubble.offset(x: bubbleOffset.x, y: bubbleOffset.y)
                }
            }
            .gesture(press)
            .help(isEmpty ? "Add an action" : (folder == nil ? label : "Rename “\(label)”"))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isEmpty ? Text("Empty Ring slot") : Text(label))
            .accessibilityAction { action() }
            .modifier(
                RingSlotClearAccessibilityAction(
                    isEmpty: isEmpty,
                    label: label,
                    clearAction: clearAction
                )
            )
    }

    /// One gesture does both jobs. A `Button` and a drag gesture fight over the
    /// same mouse-down — whichever wins, the other stops firing — so the press
    /// decides for itself: barely moved is a click, anything further is the disc
    /// being carried to another slot.
    private var press: some Gesture {
        // Global space: a carried disc is offset as it moves, and a local
        // measurement would be reading its own movement back into itself.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard let onDragChanged else { return }
                if !carrying {
                    let travelled = hypot(value.translation.width, value.translation.height)
                    guard travelled > RingDragTargeting.clickSlop else { return }
                    carrying = true
                }
                onDragChanged(value.translation)
            }
            .onEnded { _ in
                guard carrying else {
                    action()
                    return
                }
                carrying = false
                onDragEnded?()
            }
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
                // A second ring around the disc says "there's another ring
                // behind this one" without spending the glyph on it.
                if folder != nil {
                    Circle()
                        .strokeBorder(FlowTheme.hairline, lineWidth: 1)
                        .padding(-5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if folder != nil {
                    Text("\(folderCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(FlowTheme.ink)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.86)))
                        .overlay(Circle().stroke(FlowTheme.hairline, lineWidth: 1))
                        .offset(x: 3, y: 3)
                }
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
        case .folder:
            Image(systemName: folder?.resolvedSymbolName ?? RingFolder.defaultSymbolName)
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
