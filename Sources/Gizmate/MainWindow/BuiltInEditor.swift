import AppKit
import SwiftUI

/// Editing one of the shipped ring actions: its name, glyph, prompt, shortcut,
/// and whether it exists at all.
///
/// Everything here is an override on top of what shipped, so a field left alone
/// stays `nil` and keeps following the app — including later improvements to the
/// shipped prompt. That is why Save compares against the shipped value rather
/// than storing whatever is in the field.
struct BuiltInEditorPanel: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    let actionID: RingActionID

    @State private var name = ""
    @State private var symbolName = ""
    @State private var prompt = ""
    @State private var usesVoice = true
    @State private var usesNotes = true
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    /// nil for the six built-ins that are actions rather than instructions —
    /// their editor simply has no Prompt section.
    private var shippedPrompt: String? {
        actionID.promptMode?.shippedPromptTemplate
    }

    /// Note only. Its notes list and its result panel are one id with one
    /// placement, so choosing an edge for it is choosing where the *list*
    /// waits — Edges' question, not this editor's. See `PanelPlacement`.
    private var panelLocalityText: String {
        if let edge = bridge.dock.edge(of: ToolRef.builtIn(actionID).storageID) {
            return "Waiting on the \(edge.displayName) edge. Change it in Edges."
        }
        return "Not on an edge. Change it in Edges."
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(FlowTheme.hairline)
            ScrollView { fields.padding(20) }
            Divider().background(FlowTheme.hairline)
            footer
        }
        .frame(width: 620, height: 620)
        .background(Color(white: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear {
            // First pass only: re-running this on a redraw would undo whatever
            // the user has typed since.
            guard !loaded else { return }
            loaded = true
            let store = bridge.builtInOverrides
            name = store.displayName(for: actionID)
            symbolName = store.overrides[actionID]?.symbol ?? ""
            prompt = store.prompt(for: actionID) ?? shippedPrompt ?? ""
            usesVoice = store.overrides[actionID]?.usesVoice ?? true
            usesNotes = store.overrides[actionID]?.usesNotes ?? true
            nameFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bridge.builtInOverrides.displayName(for: actionID))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                Text(actionID.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(FlowTheme.subtleFill))
            }
            .plainButton()
            .help("Close")
            .accessibilityLabel("Close editor")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingRow("Name") {
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.ink)
                    .focused($nameFocused)
                    .frame(width: 220)
            }

            Divider().background(FlowTheme.hairline)

            shortcutRow

            // Trigger, then where what it shows turns up. A screen edge replaces
            // this action's panel — it is not a second Ring.
            if DockCatalog.dockableBuiltIns.contains(actionID) {
                Divider().background(FlowTheme.hairline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Panel")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    if PanelPlacement.offersPicker(for: actionID) {
                        // Where this action's answer opens. Chosen here, not in
                        // Edges: it draws nothing until the action runs, so it
                        // never shares an edge with anything and has no tab
                        // order to be arranged in. See DESIGN.md §11.
                        DockPlacementPicker(
                            store: bridge.dock,
                            itemID: ToolRef.builtIn(actionID).storageID
                        )
                        Text("Floating opens it at the cursor. An edge opens it flush to "
                            + "that side of the screen instead.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(panelLocalityText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(FlowTheme.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider().background(FlowTheme.hairline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkSecondary)
                IconGrid(selection: $symbolName, height: 108)
            }

            if shippedPrompt != nil {
                Divider().background(FlowTheme.hairline)
                promptSection
                Divider().background(FlowTheme.hairline)
                contextToggles
            }
        }
    }

    /// Same two context sources a gizmo carries, offered to the three built-ins
    /// that brief the model. The rest are macOS actions with no prompt to hand
    /// anything to — see `RingActionID.promptMode`.
    private var contextToggles: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingRow(
                "Use my Voice",
                subtitle: "Writes in your register, with your dictionary and snippets."
            ) {
                Toggle("", isOn: $usesVoice)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }
            SettingRow(
                "Use my notes",
                subtitle: "Hands it the notes you ticked in the Notes tab as background."
            ) {
                Toggle("", isOn: $usesNotes)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(FlowTheme.accent)
            }
        }
    }

    @ViewBuilder
    private var shortcutRow: some View {
        if let action = actionID.shortcutAction {
            SettingRow("Shortcut") {
                HStack(spacing: 8) {
                    KeyCap(text: bridge.settings.shortcut(for: action).displayString)
                    SecondaryButton(title: "Change") {
                        bridge.perform(.recordShortcut(action))
                    }
                    .padding(.leading, 4)
                }
            }
        } else {
            SettingRow(
                "Shortcut",
                subtitle: "Ring only — this one shows up in supported apps, so a global key would do nothing everywhere else."
            ) {
                EmptyView()
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.inkSecondary)
            Text("Replaces the shipped instruction. Keep the {tokens} — they carry your language, app context and writing style into the result.")
                .font(.system(size: 11.5))
                .foregroundStyle(FlowTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            PlainTextEditor(text: $prompt)
                .frame(minHeight: 180)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(FlowTheme.hairline, lineWidth: 1)
                )
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            SecondaryButton(title: "Reset to default") { resetToDefault() }
            Spacer(minLength: 0)
            SecondaryButton(title: "Cancel") { dismiss() }
            Button(action: save) {
                Text("Save")
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
            .plainButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Each field is stored only when it actually differs from what shipped, so
    /// an untouched name keeps following the app rather than freezing today's.
    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let shipped = shippedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        bridge.builtInOverrides.save(
            BuiltInOverride(
                name: (trimmedName.isEmpty || trimmedName == actionID.displayName)
                    ? nil : trimmedName,
                symbol: symbolName.isEmpty ? nil : symbolName,
                prompt: (trimmedPrompt.isEmpty || trimmedPrompt == shipped)
                    ? nil : trimmedPrompt,
                usesVoice: usesVoice,
                usesNotes: usesNotes
            ),
            for: actionID
        )
        dismiss()
    }

    private func resetToDefault() {
        bridge.builtInOverrides.resetToDefault(actionID)
        dismiss()
    }

    private func dismiss() {
        nameFocused = false
        bridge.closeRingSheet()
    }
}
