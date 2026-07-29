import SwiftUI

/// The secrets picker inside a tool's editor: which of the user's stored
/// credentials this tool is handed, plus a way to add one without leaving.
///
/// Deliberately not a separate settings pane. You find out you need a key at the
/// moment you are wiring up the tool that wants it, and a pane somewhere else is
/// a trip away from the thing you were doing. The trade is that a user with no
/// tools has nowhere to pre-load keys — which is fine, because a key with no
/// tool to read it does nothing.
///
/// Values are write-only here on purpose: a stored secret shows as `••••••••`
/// and can be replaced or removed, never read back. A settings window is a
/// screen-shared, screenshotted, shoulder-surfed place.
struct ToolSecretsPicker: View {
    @Binding var selection: [String]

    /// Refreshed from disk rather than observed: `ToolSecrets` is a handful of
    /// files with no change notification, and the only thing that writes them is
    /// this view.
    ///
    /// Loaded in `onAppear`, not as a default value. A `@State` initializer runs
    /// every time SwiftUI re-creates the view struct — which is on every render
    /// pass — so putting a directory create-and-list there puts filesystem I/O
    /// in the render loop.
    @State private var stored: [String] = []
    @State private var isAdding = false
    @State private var newName = ""
    @State private var newValue = ""
    @State private var problem: String?
    /// The secret whose value is being replaced, if any.
    @State private var editing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if stored.isEmpty && !isAdding {
                Text("No secrets stored. Add one to let this tool read an API key "
                    + "from its environment instead of carrying the key in its code.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(stored, id: \.self) { name in
                row(for: name)
            }

            if isAdding || editing != nil {
                addOrReplaceForm
            } else {
                SecondaryButton(title: "Add a secret") {
                    isAdding = true
                    newName = ""
                    newValue = ""
                    problem = nil
                }
            }

            if let problem {
                Text(problem)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 0.92, green: 0.45, blue: 0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !selection.isEmpty {
                Text("This tool reads \(selection.sorted().joined(separator: ", ")) "
                    + "from its environment. You are asked to confirm again whenever "
                    + "that list changes.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { stored = ToolSecrets.names() }
    }

    private func row(for name: String) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { selection.contains(name) },
                set: { isOn in
                    selection.removeAll { $0 == name }
                    if isOn { selection.append(name) }
                    selection.sort()
                }
            )) {
                Text(name)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(FlowTheme.ink)
            }
            .toggleStyle(.checkbox)
            .tint(FlowTheme.accent)

            Text("••••••••")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(FlowTheme.inkTertiary)

            Spacer(minLength: 8)

            Button("Replace") {
                editing = name
                isAdding = false
                newName = name
                newValue = ""
                problem = nil
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))

            Button("Remove") {
                ToolSecrets.delete(name)
                selection.removeAll { $0 == name }
                stored = ToolSecrets.names()
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
        }
    }

    private var addOrReplaceForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("OPENAI_API_KEY", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(FlowTheme.ink)
                    .disabled(editing != nil)
                    .frame(width: 220)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))

                // SecureField, so the key is not sitting in plain sight in a
                // window people share.
                SecureField("Paste the value", text: $newValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(FlowTheme.ink)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FlowTheme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
            }

            HStack(spacing: 10) {
                SecondaryButton(title: editing == nil ? "Save" : "Replace") { save() }
                SecondaryButton(title: "Cancel") {
                    isAdding = false
                    editing = nil
                    problem = nil
                }
            }

            Text("Uppercase letters, digits and underscores — it becomes an "
                + "environment variable the script reads by that exact name.")
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FlowTheme.subtleFill.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlowTheme.hairline, lineWidth: 1))
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ToolSecrets.isValidName(name) else {
            problem = "“\(name)” isn't a usable name. Use uppercase letters, digits "
                + "and underscores, starting with a letter."
            return
        }
        guard ToolSecrets.set(newValue, for: name) else {
            problem = "That value is empty, or the secret couldn't be written to disk."
            return
        }
        stored = ToolSecrets.names()
        // Adding a secret from a tool's own editor means that tool wants it;
        // making the user then tick the box they just created is busywork.
        if editing == nil, !selection.contains(name) {
            selection.append(name)
            selection.sort()
        }
        isAdding = false
        editing = nil
        newName = ""
        newValue = ""
        problem = nil
    }
}
