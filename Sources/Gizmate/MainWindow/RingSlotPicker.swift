import AppKit
import SwiftUI

/// What the Ring tab currently has open over the window.
/// Which position, in which ring. `path` is empty for the root ring; each id
/// descends into that folder. Slots outside the root ring exist as soon as a
/// folder does, so an index alone can no longer name one.
enum RingSheet: Equatable {
    /// Choosing what goes in one slot.
    case slot(RingSlotAddress)
    /// What a gizmo *is*: its name, icon, kind, trigger and script.
    ///
    /// Never nil, and that is the point. A nil id used to mean "a new one", and
    /// opened this same panel on a second builder chat. Gizmos are built by
    /// talking to Home, so there is nothing for a second builder to do, and an
    /// editor that can only edit something that exists needs no empty state.
    case toolEditor(id: UUID)
    /// Naming a sub-ring. `id` is nil for a new folder, in which case
    /// `assignTo` is the slot it lands in; a non-nil `id` is a rename.
    case folderEditor(id: UUID?, assignTo: RingSlotAddress?)
    /// Editing one of the shipped actions: name, icon, prompt, shortcut, on/off.
    case builtInEditor(RingActionID)
}

/// Dims the whole window and centers the active Ring panel. Same arrangement as
/// `ModelPickerOverlay` — rendered at the window root so the scrim reaches the
/// sidebar, click-outside and Escape both dismiss.
struct RingSheetOverlay: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let sheet: RingSheet

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            switch sheet {
            case .slot(let address):
                RingSlotPickerPanel(toolsStore: bridge.tools, address: address)
            case .toolEditor(let id):
                // The draft comes from the builder, not from the id, so this
                // modal and the chat are editing one object rather than two
                // copies that would overwrite each other on save.
                if let builder = bridge.host?.gizmoBuilder {
                    ToolEditorPanel(gizmo: builder.draft(for: .existing(id)), builder: builder)
                }
            case .folderEditor(let id, let assignTo):
                RingFolderEditorPanel(folderID: id, assignTo: assignTo)
            case .builtInEditor(let id):
                BuiltInEditorPanel(actionID: id)
            }
        }
        .onExitCommand(perform: close)
    }

    private func close() {
        bridge.closeRingSheet()
    }
}

// MARK: - Slot picker

private struct RingSlotPickerPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// Observed so the list refreshes the moment a tool is deleted.
    @ObservedObject var toolsStore: ToolsStore
    let address: RingSlotAddress

    @State private var group: Group = .builtIn
    @State private var pending: RingSlotContent?

    private enum Group: String, CaseIterable {
        case builtIn = "Built-in actions"
        case tools = "Your gizmos"
    }

    private var ring: RingLayout {
        bridge.ringLayout.ring(at: address.path) ?? bridge.ringLayout.layout
    }

    private var current: RingSlotContent {
        ring.slots[safe: address.index] ?? .empty
    }

    private var builtIns: [RingActionID] { RingActionID.allCases }

    private var tools: [GizmateTool] {
        toolsStore.tools.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(FlowTheme.hairline)
            sourceBar
            Divider().background(FlowTheme.hairline)
            listColumn
            Divider().background(FlowTheme.hairline)
            footer
        }
        .frame(width: 640, height: 560)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear {
            pending = current == .empty ? nil : current
            if case .tool = current { group = .tools }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose an action")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text("Currently: \(describe(current))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer()
            Button(action: { closePanel() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .plainButton()
            .help("Close")
            .accessibilityLabel("Close action picker")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            sourceTab(.builtIn, count: builtIns.count)
            sourceTab(.tools, count: tools.count)
            Spacer(minLength: 0)
            // The ring can draw three orbits, so a sub-ring only fits while
            // there's still an orbit left to fan its contents into.
            if RingFolderDepth.allowsFolder(at: address.path) {
                newButton(symbol: RingFolder.defaultSymbolName, title: "New sub-ring") {
                    bridge.ringSheet = .folderEditor(id: nil, assignTo: address)
                }
                .help("Puts a button here that opens a ring of its own.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// This panel answers one question — what goes in this slot — so its full
    /// width belongs to the answer. Building a gizmo used to sit here; it lives
    /// on Home now, which is the section that answers "what can Gizmate do".
    private var footer: some View {
        Button {
            if let pending { assign(pending) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Save to ring")
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(Color(white: 0.08))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlowTheme.accentBright)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .plainButton()
        .disabled(pending == nil)
        .opacity(pending == nil ? 0.4 : 1)
        .help("Puts the selected action in this slot.")
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func newButton(symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(FlowTheme.accent)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .plainButton()
    }

    private func sourceTab(_ value: Group, count: Int) -> some View {
        let isSelected = value == group
        return Button { group = value } label: {
            HStack(spacing: 6) {
                Text(value.rawValue)
                Text("\(count)")
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? FlowTheme.ink : FlowTheme.inkSecondary)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FlowTheme.accentSoft : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .plainButton()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var listColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                switch group {
                case .builtIn:
                    ForEach(builtIns, id: \.self) { id in
                        optionRow(
                            content: .builtIn(id),
                            symbolImage: AnyView(
                                Image(nsImage: bridge.builtInOverrides.icon(for: id).image(pointSize: 15))
                                    .renderingMode(.template)
                            ),
                            title: bridge.builtInOverrides.displayName(for: id),
                            detail: id.summary,
                            // A built-in is taken out of the ring by replacing
                            // the slot, never deleted, so it gets the gear
                            // gizmo rows have but no trash.
                            onEdit: { bridge.ringSheet = .builtInEditor(id) }
                        )
                    }
                case .tools:
                    if tools.isEmpty {
                        Text("No gizmos yet. Build one from Home.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    ForEach(tools) { tool in
                        optionRow(
                            content: .tool(tool.id),
                            symbolImage: AnyView(Image(systemName: tool.resolvedSymbolName)),
                            title: tool.name.isEmpty ? "Untitled gizmo" : tool.name,
                            detail: tool.isUsable
                                ? tool.output.explanation
                                : "Unfinished — this gizmo still needs a prompt.",
                            // Managing tools lives here: the Ring tab itself shows
                            // only the ring.
                            onEdit: {
                                bridge.ringSheet = .toolEditor(id: tool.id)
                            },
                            onDelete: { delete(tool) }
                        )
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func optionRow(
        content: RingSlotContent,
        symbolImage: AnyView,
        title: String,
        detail: String,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        let isPending = pending == content
        return HStack(spacing: 4) {
            HStack(spacing: 11) {
                symbolImage
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(FlowTheme.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 8)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            // Not a Button: a Button eats the click before a double can form.
            // Selecting has to land on mouse-up of the first click — see
            // `onClick`, which is what a rival count-2 gesture would delay.
            .onClick({ pending = content }, double: { assign(content) })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isPending ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Assign") { assign(content) }

            // Row controls belong to the selected row only — otherwise every row
            // carries a column of icons and the list reads as a toolbar.
            if isPending {
                if let onEdit {
                    RowIconButton(symbol: "gearshape", action: onEdit)
                        .help("Edit \(title)")
                        .accessibilityLabel("Edit \(title)")
                }
                if let onDelete {
                    RowIconButton(symbol: "trash", action: onDelete)
                        .help("Delete \(title)")
                        .accessibilityLabel("Delete \(title)")
                        .padding(.trailing, 8)
                }
            }
        }
        .background(isPending ? Color.white.opacity(0.06) : Color.clear)
    }

    private func assign(_ content: RingSlotContent) {
        pending = content
        bridge.ringLayout.assign(content, to: address.index, in: address.path)
        closePanel()
    }

    /// Deleting a tool removes its folder and its script for good, so it asks
    /// first — there's no undo behind this.
    private func delete(_ tool: GizmateTool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(tool.name)”?"
        alert.informativeText = tool.kind == .python
            ? "Its script is deleted too. This can't be undone."
            : "This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        bridge.ringLayout.removeTool(tool.id)
        bridge.tools.delete(tool.id)
        ToolApprovals.revoke(tool.id)
        if pending == .tool(tool.id) { pending = nil }
    }

    private func closePanel() {
        bridge.closeRingSheet()
    }

    private func describe(_ content: RingSlotContent) -> String {
        switch content {
        case .empty:
            return "empty"
        case .builtIn(let id):
            return id.displayName
        case .tool(let id):
            return bridge.tools.tool(id: id)?.name ?? "a deleted gizmo"
        case .folder(let id):
            return bridge.ringLayout.folder(id).map { "“\($0.name)” sub-ring" } ?? "a deleted sub-ring"
        }
    }
}

extension Array {
    /// Bounds-checked read, so a slot index can't trap a settings view.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
