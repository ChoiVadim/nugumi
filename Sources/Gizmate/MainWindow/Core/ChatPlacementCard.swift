import SwiftUI

/// Asks where a just-saved gizmo lives, then says how to use it from there.
///
/// The ring is offered as the ring itself, not as a list of slot numbers: the
/// same `RingDiagram` the Ring section draws, so the level (ring or one of its
/// folders) and the slot are one tap on the picture, and hovering a folder
/// opens it exactly as it does there.
struct ChatPlacementCard: View {
    let stage: ToolPlacementStage
    @ObservedObject var ringLayout: RingLayoutStore
    let tools: [GizmateTool]
    let onChoose: (ToolHome) -> Void
    let onPickSlot: (RingSlotAddress) -> Void
    let onOpen: (MainWindowSection) -> Void

    @State private var choosingSlot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch stage {
            case .choosing(let tool):
                choosing(tool)
            case .settled(_, let note, let section):
                settled(note, section: section)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func choosing(_ tool: GizmateTool) -> some View {
        Text("\(tool.name) is saved. Where should it live?")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(FlowTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
        if choosingSlot {
            Text("Tap a slot. Hover a folder to open it; a full slot is replaced.")
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .padding(.horizontal, 16)
            RingDiagram(
                layout: ringLayout.layout,
                tools: tools,
                folders: ringLayout.folders,
                onPick: onPickSlot,
                onEditFolder: { _ in },
                onClear: { ringLayout.clear($0.index, in: $0.path) },
                canMove: { ringLayout.canMove(from: $0, to: $1) },
                onMove: { ringLayout.move(from: $0, to: $1) }
            )
            .frame(height: 360)
            .padding(.horizontal, 8)
            SecondaryButton(title: "Back") { choosingSlot = false }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        } else {
            ForEach(Array(ToolHome.offered(for: tool.output).enumerated()), id: \.offset) { index, home in
                Divider().background(FlowTheme.hairline)
                ChatOptionRow(number: index + 1, label: home.label) {
                    if home == .ring {
                        choosingSlot = true
                    } else {
                        onChoose(home)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settled(_ note: String, section: MainWindowSection?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let section {
                SecondaryButton(title: "Open \(section.title)") { onOpen(section) }
            }
        }
        .padding(16)
    }
}
