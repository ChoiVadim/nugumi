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
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let sheet: RingSheet

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { bridge.ringSheet = nil }
            switch sheet {
            case .slot(let index):
                RingSlotPickerPanel(slotIndex: index)
            case .toolEditor(let id, let assignTo):
                PromptToolEditorPanel(toolID: id, assignTo: assignTo)
            }
        }
        .onExitCommand { bridge.ringSheet = nil }
    }
}

// MARK: - Slot picker

/// Two-pane picker for one ring slot. Left column groups the sources, right
/// column lists them, and the choice is staged until Assign commits it — so a
/// stray click never rearranges the ring. Mirrors `ModelPickerPanel`.
private struct RingSlotPickerPanel: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
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

    private var tools: [PromptTool] {
        bridge.promptTools.tools
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
            HStack(spacing: 0) {
                groupColumn
                Divider().background(FlowTheme.hairline)
                listColumn
            }
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
            if case .promptTool = current { group = .tools }
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
            Button(action: { bridge.ringSheet = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .buttonStyle(.plain)
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

    private var groupColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            groupRow(.builtIn, count: builtIns.count)
            groupRow(.tools, count: tools.count)
            Divider().background(FlowTheme.hairline).padding(.vertical, 8)
            Button {
                bridge.ringSheet = .toolEditor(id: nil, assignTo: slotIndex)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("New prompt tool")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(FlowTheme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 200)
    }

    private func groupRow(_ value: Group, count: Int) -> some View {
        let isSelected = value == group
        return Button { group = value } label: {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(isSelected ? FlowTheme.accent : Color.clear)
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.rawValue)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isSelected ? FlowTheme.ink : FlowTheme.inkSecondary)
                    Text("\(count) \(count == 1 ? "item" : "items")")
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkTertiary)
                }
                .padding(.vertical, 7)
                .padding(.leading, 12)
                Spacer(minLength: 0)
            }
            .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        Text("No tools yet. Use “New prompt tool” on the left.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                    ForEach(tools) { tool in
                        optionRow(
                            content: .promptTool(tool.id),
                            symbolImage: AnyView(Image(systemName: tool.resolvedSymbolName)),
                            title: tool.name.isEmpty ? "Untitled tool" : tool.name,
                            detail: tool.isUsable
                                ? tool.result.explanation
                                : "Unfinished — this tool still needs a prompt.",
                            // Editing (and deleting, from the editor's footer)
                            // lives here: the Ring tab itself shows only the ring.
                            onEdit: {
                                bridge.ringSheet = .toolEditor(id: tool.id, assignTo: slotIndex)
                            }
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
        onEdit: (() -> Void)? = nil
    ) -> some View {
        let isPending = pending == content
        let assignedElsewhere = bridge.ringLayout.layout.slots.contains(content) && content != current
        return Button { pending = content } label: {
            HStack(spacing: 11) {
                symbolImage
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(FlowTheme.ink)
                        if assignedElsewhere { RingTag(text: "moves here") }
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let onEdit {
                    RowIconButton(symbol: "pencil", action: onEdit)
                }
                if isPending {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(FlowTheme.accent)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(isPending ? Color.white.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if current != .empty {
                SecondaryButton(title: "Remove from ring", destructive: true) {
                    bridge.ringLayout.clear(slotIndex)
                    bridge.ringSheet = nil
                }
            }
            Spacer(minLength: 0)
            SecondaryButton(title: "Cancel") { bridge.ringSheet = nil }
            Button {
                guard let pending else { return }
                bridge.ringLayout.assign(pending, to: slotIndex)
                bridge.ringSheet = nil
            } label: {
                Text("Assign")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(FlowTheme.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(pending == nil || pending == current)
            .opacity(pending == nil || pending == current ? 0.45 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func describe(_ content: RingSlotContent) -> String {
        switch content {
        case .empty:
            return "empty"
        case .builtIn(let id):
            return id.displayName
        case .promptTool(let id):
            return bridge.promptTools.tool(id: id)?.name ?? "a deleted tool"
        }
    }
}

// MARK: - Prompt tool editor

/// Draft-based editor: nothing reaches the store until Save, so Cancel and
/// Escape are always safe.
private struct PromptToolEditorPanel: View {
    @EnvironmentObject var bridge: NugumiSettingsBridge
    let toolID: UUID?
    let assignTo: Int?

    @State private var draft = PromptTool()
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    private var isNew: Bool { toolID == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(FlowTheme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameAndIcon
                    promptField
                    resultPicker
                    languageToggle
                }
                .padding(16)
            }
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
            guard !loaded else { return }
            loaded = true
            if let toolID, let existing = bridge.promptTools.tool(id: toolID) {
                draft = existing
            }
            nameFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New prompt tool" : "Edit tool")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text("Your prompt runs over the selected text. Nugumi adds nothing else to it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
            Spacer()
            Button(action: { bridge.ringSheet = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var nameAndIcon: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel("Name", hint: "Shown on the ring button when you hover it.")
            TextField("To JSON", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
                .focused($nameFocused)
                .padding(.vertical, 8)
                .padding(.horizontal, 11)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))

            fieldLabel("Icon")
            IconGrid(selection: $draft.symbolName)
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldLabel(
                "Prompt",
                hint: "Write it as an instruction to the model, the way you'd brief a person."
            )
            TextEditor(text: $draft.prompt)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.ink)
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
        }
    }

    private var resultPicker: some View {
        SettingRow("Result", subtitle: draft.result.explanation) {
            PillPicker(
                options: PromptToolResult.allCases,
                selection: $draft.result,
                label: { $0.displayName }
            )
        }
    }

    private var languageToggle: some View {
        SettingRow(
            "Write the answer in the target language",
            subtitle: "Leave this off for tools that transform text rather than translate it."
        ) {
            Toggle("", isOn: $draft.appliesTargetLanguage)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let toolID {
                SecondaryButton(title: "Delete", destructive: true) {
                    bridge.ringLayout.removeTool(toolID)
                    bridge.promptTools.delete(toolID)
                    bridge.ringSheet = nil
                }
            }
            Spacer(minLength: 0)
            SecondaryButton(title: "Cancel") { bridge.ringSheet = nil }
            Button(action: save) {
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(FlowTheme.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!draft.isUsable)
            .opacity(draft.isUsable ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func save() {
        guard draft.isUsable else { return }
        var tool = draft
        tool.name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.prompt = tool.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNew {
            bridge.promptTools.add(tool)
        } else {
            bridge.promptTools.update(tool)
        }
        if let assignTo {
            bridge.ringLayout.assign(.promptTool(tool.id), to: assignTo)
        }
        bridge.ringSheet = nil
    }

    private func fieldLabel(_ title: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkTertiary)
            }
        }
    }
}

/// Scrolling grid of the curated SF Symbols in `PromptToolIcons`.
private struct IconGrid: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 12)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(PromptToolIcons.all, id: \.self) { name in
                    let isSelected = name == selection
                    Button { selection = name } label: {
                        Image(systemName: name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? .white : FlowTheme.inkSecondary)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? FlowTheme.accent : Color.white.opacity(0.05))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            .padding(8)
        }
        .frame(height: 108)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }
}

extension Array {
    /// Bounds-checked read, so a slot index can't trap a settings view.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
