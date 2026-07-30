import AppKit
import SwiftUI

// MARK: - Settings

/// How Gizmate behaves while you work, plus the hotkeys that reach it. Both
/// answer "how is this thing set up", so they share one sidebar entry.
struct SettingsSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailContainer(
            "Settings",
            subtitle: bridge.settingsTab == 0
                ? "How Gizmate shows up while you work."
                : "Global hotkeys that work from any app.",
            pinned: FlowTabBar(tabs: ["General", "Shortcuts"], selection: $bridge.settingsTab),
            accessory: bridge.settingsTab == 1
                ? AnyView(SecondaryButton(title: "Reset to defaults") { bridge.perform(.resetShortcuts) })
                : nil
        ) {
            if bridge.settingsTab == 0 {
                GeneralTab()
            } else {
                ShortcutsTab()
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    /// Actions bucketed into their display groups, preserving allCases order
    /// within each group.
    private var groups: [(group: ShortcutGroup, actions: [GlobalShortcutAction])] {
        ShortcutGroup.allCases.compactMap { group in
            let actions = GlobalShortcutAction.allCases.filter { $0.group == group }
            return actions.isEmpty ? nil : (group, actions)
        }
    }

    var body: some View {
        Group {
            ForEach(groups, id: \.group) { group, actions in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .padding(.leading, 4)
                    SubCard {
                        VStack(spacing: 18) {
                            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                                if index > 0 { Divider().background(FlowTheme.hairline) }
                                shortcutRow(action)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: GlobalShortcutAction) -> some View {
        SettingRow(action.menuTitle) {
            HStack(spacing: 8) {
                KeyCap(text: bridge.settings.shortcut(for: action).displayString)
                // Ask Gizmate also fires on a fixed ⌃⌥A alias — shown muted since
                // "Change" only rebinds the primary (double-tap ⌃) shortcut.
                if action == .askGizmate {
                    KeyCap(text: GlobalShortcutAction.askGizmateAlias.displayString, muted: true)
                }
                SecondaryButton(title: "Change") {
                    bridge.perform(.recordShortcut(action))
                }
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: - General behaviour

private struct GeneralTab: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        Group {
            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Main mode",
                               subtitle: "What the floating button and pet do on a single click.") {
                        PillPicker(options: [.translate, .smartReply],
                                   selection: bridge.binding(\.floatingDefaultMode) { .setFloatingDefaultMode($0) },
                                   label: { $0 == .translate ? "Translate" : "Reply" })
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("On selection",
                               subtitle: "What appears when you select text.") {
                        PillPicker(options: SelectionDisplayMode.allCases,
                                   selection: bridge.binding(\.selectionDisplayMode) { .setSelectionDisplayMode($0) },
                                   label: { $0.menuTitle })
                    }
                }
            }

            SubCard {
                VStack(spacing: 18) {
                    SettingRow("Launch at login",
                               subtitle: "Start Gizmate automatically when you log in to your Mac.") {
                        Toggle("", isOn: bridge.binding(\.launchAtLogin) { .setLaunchAtLogin($0) })
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(FlowTheme.accent)
                    }
                    Divider().background(FlowTheme.hairline)
                    SettingRow("Invisibility mode",
                               subtitle: "Hide Gizmate's windows from screen recording and screenshots.") {
                        Toggle("", isOn: Binding(
                            get: { bridge.settings.invisibilityEnabled },
                            set: { _ in bridge.perform(.toggleInvisibility) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(FlowTheme.accent)
                    }
                }
            }
        }
    }
}

/// Free-text background about the user, appended to every prompt so answers
/// pick the meaning most relevant to them (e.g. "RLS" → Row-Level Security for
/// a developer). Written straight to UserDefaults — prompts read it at request
/// time, so no bridge state is involved.
struct AboutYouTab: View {
    @State private var draft = UserAboutContext.text

    var body: some View {
        Group {
            PageBanner(
                title: "Better answers, your context",
                message: "When a term has several meanings, Gizmate picks the one most relevant to you - \"RLS\" means row-level security to a developer, not a sleep disorder.",
                symbol: "person.crop.circle"
            )

            SubCard {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Who you are")
                            .font(FlowTheme.serif(19))
                            .foregroundStyle(FlowTheme.ink)

                        Text("A couple of sentences is plenty. Worth mentioning:")
                            .font(.system(size: 12.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 12) {
                            hintRow("briefcase", "What you do - \"iOS developer\", \"nurse\", \"law student\".")
                            hintRow("wrench.and.screwdriver", "Tools and topics you live in - PostgreSQL, Figma, crypto.")
                            hintRow("sparkles", "Anything that shapes what you read and write every day.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(FlowTheme.hairline)
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Background")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FlowTheme.inkSecondary)

                        PlainTextEditor(text: $draft)
                            .frame(minHeight: 150, maxHeight: 280)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                if draft.isEmpty {
                                    Text("I'm a software developer at a fintech startup.\nI work with PostgreSQL, Swift, and TypeScript.\nOutside work I follow F1 and read about space.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(FlowTheme.inkTertiary.opacity(0.55))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.vertical, 9)
                                        .padding(.horizontal, 12)
                                        .allowsHitTesting(false)
                                }
                            }
                            .onChange(of: draft) { _, newValue in
                                UserAboutContext.text = newValue
                            }

                        Text("\(draft.count) / \(UserAboutContext.maxLength)")
                            .font(.system(size: 11))
                            .foregroundStyle(draft.count > UserAboutContext.maxLength ? Color(red: 1.0, green: 0.62, blue: 0.62) : FlowTheme.inkTertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func hintRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Library (Dictionary & Snippets)

/// The words Gizmate reuses: names it must keep verbatim, and shorthand it
/// expands. Both are the same list over a different `SnippetKind`.
struct LibrarySection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// Owned here, not in the list, because the "Add" button that flips it
    /// lives in the section header alongside the tab bar.
    @State private var isAddingNew = false

    private var kind: SnippetKind { bridge.libraryTab == 0 ? .dictionaryTerm : .snippet }

    var body: some View {
        DetailContainer(
            "Library",
            subtitle: kind == .snippet
                ? "Short phrases Gizmate expands before rewriting."
                : "Words and names Gizmate keeps exactly as written.",
            pinned: FlowTabBar(tabs: ["Dictionary", "Snippets"], selection: tabSelection),
            accessory: AnyView(
                SecondaryButton(title: kind == .snippet ? "Add snippet" : "Add word") {
                    isAddingNew = true
                }
            )
        ) {
            SnippetsListContent(store: bridge.snippets, kind: kind, isAddingNew: $isAddingNew)
                // Fresh identity per tab so a row left open for editing in one
                // list doesn't reappear as an open editor in the other.
                .id(kind)
        }
    }

    /// Switching tabs abandons a half-written new entry rather than carrying
    /// the open editor across to the other list.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { bridge.libraryTab },
            set: { bridge.libraryTab = $0; isAddingNew = false }
        )
    }
}

private struct SnippetsListContent: View {
    @ObservedObject var store: SnippetsStore
    let kind: SnippetKind
    @Binding var isAddingNew: Bool

    @State private var editingID: UUID?

    /// Newest first, so a just-saved entry lands where the add editor was.
    private var items: [Snippet] {
        store.snippets
            .filter { $0.kind == kind }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if items.isEmpty && !isAddingNew {
                SubCard {
                    Text(kind == .snippet
                         ? "No snippets yet. Add one like “omw” → “on my way”."
                         : "No saved words yet. Add names or terms Gizmate should never translate.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 0) {
                    if isAddingNew {
                        SnippetEditorRow(
                            kind: kind,
                            initialTrigger: "",
                            initialValue: "",
                            onSave: { trigger, value in
                                let created = store.add(kind: kind)
                                store.update(created.id, trigger: trigger, value: value)
                                isAddingNew = false
                            },
                            onCancel: { isAddingNew = false }
                        )
                        .id("snippet-editor-new")
                        if !items.isEmpty { Divider().background(FlowTheme.hairline) }
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().background(FlowTheme.hairline) }
                        if editingID == item.id {
                            SnippetEditorRow(
                                kind: kind,
                                initialTrigger: item.trigger,
                                initialValue: item.value,
                                onSave: { trigger, value in
                                    store.update(item.id, trigger: trigger, value: value)
                                    editingID = nil
                                },
                                onCancel: { editingID = nil }
                            )
                            .id("snippet-editor-\(item.id)")
                        } else {
                            SnippetDisplayRow(
                                snippet: item,
                                onEdit: {
                                    isAddingNew = false
                                    editingID = item.id
                                },
                                onDelete: { store.delete(item.id) }
                            )
                        }
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
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        // The header's Add button can't reach `editingID`; close any open row
        // editor when it opens the new-entry editor.
        .onChange(of: isAddingNew) { _, adding in
            if adding { editingID = nil }
        }
    }
}

/// Flow-style display row: plain text, hover highlights the row and reveals
/// edit/delete actions. Double-click also opens the editor.
private struct SnippetDisplayRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(snippet.trigger.isEmpty ? "—" : snippet.trigger)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
                .lineLimit(1)
            if snippet.kind == .snippet {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkTertiary)
                Text(snippet.value)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                RowIconButton(symbol: "pencil", action: onEdit)
                RowIconButton(symbol: "trash", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .background(hovering ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onEdit() }
    }
}

/// Draft-based inline editor: nothing touches the store until Save / Return.
/// Esc cancels.
private struct SnippetEditorRow: View {
    let kind: SnippetKind
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var trigger: String
    @State private var value: String
    @FocusState private var focusedField: Field?

    private enum Field { case trigger, value }

    init(
        kind: SnippetKind,
        initialTrigger: String,
        initialValue: String,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.kind = kind
        self.onSave = onSave
        self.onCancel = onCancel
        _trigger = State(initialValue: initialTrigger)
        _value = State(initialValue: initialValue)
    }

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            editorField(
                kind == .snippet ? "Shortcut" : "Word or name",
                text: $trigger,
                weight: .medium
            )
            .frame(maxWidth: kind == .snippet ? 170 : .infinity)
            .focused($focusedField, equals: .trigger)
            .onSubmit {
                if kind == .snippet {
                    focusedField = .value
                } else {
                    commit()
                }
            }

            if kind == .snippet {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkTertiary)
                editorField("Expands to…", text: $value, weight: .regular)
                    .frame(maxWidth: .infinity)
                    .focused($focusedField, equals: .value)
                    .onSubmit { commit() }
            }

            SecondaryButton(title: "Save", action: commit)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)

            RowIconButton(symbol: "xmark", action: onCancel)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(Color.white.opacity(0.05))
        .onAppear { focusedField = .trigger }
        .onExitCommand { onCancel() }
    }

    private func commit() {
        guard canSave else { return }
        onSave(
            trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func editorField(_ placeholder: String, text: Binding<String>, weight: Font.Weight) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: weight))
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
    }
}

// MARK: - Help

struct HelpSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        DetailContainer("Help", subtitle: "Setup, support, and housekeeping.") {
            SubCard {
                VStack(spacing: 16) {
                    HelpRow(title: "How to use Gizmate",
                            subtitle: "Permission setup and a quick feature tour.",
                            button: "Open") {
                        bridge.perform(.openPermissionsHelp)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Contact support",
                            subtitle: "Found a bug or have a request? Email Vadim.",
                            button: "Email") {
                        bridge.perform(.contactSupport)
                    }
                    if bridge.isAppBundle {
                        Divider().background(FlowTheme.hairline)
                        HelpRow(title: "Check for updates",
                                subtitle: "Currently on v\(bridge.appVersion).",
                                button: "Check") {
                            bridge.perform(.checkForUpdates)
                        }
                    }
                }
            }
            SubCard {
                VStack(spacing: 16) {
                    HelpRow(title: "Reset all settings",
                            subtitle: "Restore defaults. Snippets, dictionary, and stats are kept.",
                            button: "Reset",
                            destructive: true) {
                        bridge.perform(.resetSettings)
                    }
                    Divider().background(FlowTheme.hairline)
                    HelpRow(title: "Quit Gizmate",
                            subtitle: "Close Gizmate completely.",
                            button: "Quit",
                            destructive: true) {
                        bridge.perform(.quit)
                    }
                }
            }
        }
    }
}

private struct HelpRow: View {
    let title: String
    let subtitle: String
    let button: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            SecondaryButton(title: button, destructive: destructive, minWidth: 76, action: action)
        }
    }
}
