import SwiftUI

// MARK: - Voice: Dictionary & Snippets tabs

/// The words Gizmate reuses: names it must keep verbatim, and shorthand it
/// expands. Both are the same list over a different `SnippetKind`. `isAddingNew`
/// is owned by `VoiceSection` because the "Add" button that flips it lives in
/// the section header alongside the tab bar.
struct SnippetsList: View {
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
