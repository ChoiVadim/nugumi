import AppKit
import SwiftUI

/// What the Ring tab currently has open over the window.
enum RingSheet: Equatable {
    /// Choosing what goes in ring slot *i*.
    case slot(Int)
    /// Writing a prompt tool. `id` is nil for a new one; `assignTo` carries the
    /// slot the user came from, so "empty slot → New prompt tool → Save" lands
    /// the finished tool in that slot without a second trip through the picker.
    case toolEditor(id: UUID?, assignTo: Int?)
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
            case .slot(let index):
                RingSlotPickerPanel(toolsStore: bridge.tools, slotIndex: index)
            case .toolEditor(let id, let assignTo):
                ToolEditorPanel(toolID: id, assignTo: assignTo)
            }
        }
        .onExitCommand(perform: close)
    }

    /// Both panels hold text fields; the responder has to come back to the window
    /// before they're torn down or the window stops routing clicks. See
    /// `ToolEditorPanel.dismiss()`.
    private func close() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        bridge.ringSheet = nil
    }
}

// MARK: - Slot picker

private struct RingSlotPickerPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// Observed so the list refreshes the moment a tool is deleted.
    @ObservedObject var toolsStore: ToolsStore
    let slotIndex: Int

    @State private var search = ""
    @State private var group: Group = .builtIn
    @State private var pending: RingSlotContent?
    @FocusState private var searchFocused: Bool

    private enum Group: String, CaseIterable {
        case builtIn = "Built-in actions"
        case tools = "Your tools"
    }

    private var current: RingSlotContent {
        bridge.ringLayout.layout.slots[safe: slotIndex] ?? .empty
    }

    private var builtIns: [RingActionID] {
        RingActionID.allCases.filter { matches($0.displayName, $0.summary) }
    }

    private var tools: [GizmateTool] {
        toolsStore.tools
            .sorted { $0.createdAt < $1.createdAt }
            .filter { matches($0.name, $0.prompt) }
    }

    private func matches(_ fields: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
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
            searchFocused = true
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
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close action picker")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowTheme.inkTertiary)
            TextField("Filter actions and tools", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)
                .focused($searchFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            sourceTab(.builtIn, count: builtIns.count)
            sourceTab(.tools, count: tools.count)
            Spacer(minLength: 0)
            Button {
                bridge.ringSheet = .toolEditor(id: nil, assignTo: slotIndex)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New tool")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(FlowTheme.accent)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        .buttonStyle(.plain)
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
                                Image(nsImage: id.icon.image(pointSize: 15))
                                    .renderingMode(.template)
                            ),
                            title: id.displayName,
                            detail: id.summary
                        )
                    }
                case .tools:
                    if tools.isEmpty {
                        Text("No tools yet. Use “New tool” above.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    ForEach(tools) { tool in
                        optionRow(
                            content: .tool(tool.id),
                            symbolImage: AnyView(Image(systemName: tool.resolvedSymbolName)),
                            title: tool.name.isEmpty ? "Untitled tool" : tool.name,
                            detail: tool.isUsable
                                ? tool.output.explanation
                                : "Unfinished — this tool still needs a prompt.",
                            // Managing tools lives here: the Ring tab itself shows
                            // only the ring.
                            onEdit: {
                                bridge.ringSheet = .toolEditor(id: tool.id, assignTo: nil)
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
            Button { pending = content } label: {
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
                    if isPending {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(FlowTheme.accent)
                    }
                }
                .padding(.vertical, 8)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onEdit {
                RowIconButton(symbol: "pencil", action: onEdit)
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
        .background(isPending ? Color.white.opacity(0.06) : Color.clear)
    }

    private var canAssign: Bool {
        pending != nil && pending != current
    }

    private var pendingIsAssignedElsewhere: Bool {
        guard let pending, pending != current else { return false }
        return bridge.ringLayout.layout.slots.contains(pending)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if pendingIsAssignedElsewhere {
                Text("Already in another slot. Assigning moves it here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer(minLength: 0)
            SecondaryButton(title: "Cancel") { closePanel() }
            Button {
                guard let pending else { return }
                bridge.ringLayout.assign(pending, to: slotIndex)
                closePanel()
            } label: {
                Text(pendingIsAssignedElsewhere ? "Move here" : "Assign")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(FlowTheme.raisedStrong)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(FlowTheme.edge, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canAssign)
            .opacity(canAssign ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    /// Same responder handoff as the editor: a text field losing the window's
    /// first responder while being removed leaves the window ignoring clicks.
    private func closePanel() {
        searchFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
        bridge.ringSheet = nil
    }

    private func describe(_ content: RingSlotContent) -> String {
        switch content {
        case .empty:
            return "empty"
        case .builtIn(let id):
            return id.displayName
        case .tool(let id):
            return bridge.tools.tool(id: id)?.name ?? "a deleted tool"
        }
    }
}

extension Array {
    /// Bounds-checked read, so a slot index can't trap a settings view.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
