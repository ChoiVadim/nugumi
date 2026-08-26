import SwiftUI

/// Everything the user asked Gizmate to keep. Ticked notes are what gizmos with
/// "Use my notes" turned on receive as background — see `NotesContext`.
struct NotesSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge
    /// The card to put the caret in — set when the header's + makes one, so a
    /// new note is typed into immediately instead of hunting for it. Owned here
    /// because the button that sets it lives in the section header.
    @State private var focusedNoteID: UUID?
    /// `nil` is the All tab. Holding the tag's id rather than a tab index keeps
    /// the selection pointing at the same tag when tags are added or removed.
    @State private var selectedTagID: UUID?
    @State private var tagEditor: TagEditorMode?

    enum TagEditorMode: Hashable {
        case adding
        case renaming(UUID)
    }

    private var tags: [NoteTag] { bridge.notes.tags }

    var body: some View {
        DetailContainer(
            "Notes",
            subtitle: subtitle,
            pinned: tagBar,
            accessory: AnyView(headerButtons)
        ) {
            if let tagEditor {
                TagEditorRow(
                    initialName: name(for: tagEditor),
                    initialSymbol: symbol(for: tagEditor),
                    onSave: { save(tagEditor, named: $0, symbol: $1) },
                    onDelete: deleteAction(for: tagEditor),
                    onCancel: { self.tagEditor = nil }
                )
                .id(tagEditor)
            }
            NotesGrid(
                store: bridge.notes,
                tagID: selectedTagID,
                focusedNoteID: $focusedNoteID
            )
        }
    }

    private var subtitle: String {
        guard let tag = bridge.notes.tag(selectedTagID) else {
            return "Anything worth keeping, in your own words."
        }
        return "Notes filed under \(tag.name)."
    }

    /// Only ever "add a note". Deleting a tag lives in that tag's own editor
    /// row — a permanent bin in the page header sits one slip away from the
    /// button next to it and names no target.
    private var headerButtons: some View {
        ResetDiscButton(
            symbol: "plus",
            label: "Add note",
            accessibilityTitle: "Add note"
        ) {
            tagEditor = nil
            // Created straight away rather than as a pending draft: with the
            // card being its own editor there is no half-state to model, and
            // an untouched card is one click on its own bin to remove.
            // ponytail: no auto-sweep of blank cards — the bin is right there.
            focusedNoteID = bridge.notes.add(tagID: selectedTagID).id
        }
    }

    /// All, then one tab per tag, then a "+" that adds one. Double-clicking a
    /// tag renames it.
    private var tagBar: some View {
        HStack(spacing: 20) {
            tab(title: "All", selected: selectedTagID == nil) { selectedTagID = nil }
            ForEach(tags) { tag in
                tab(
                    title: tag.name,
                    selected: selectedTagID == tag.id,
                    action: { selectedTagID = tag.id },
                    onRename: { tagEditor = .renaming(tag.id) }
                )
            }
            Button {
                tagEditor = .adding
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .padding(.bottom, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tag")
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlowTheme.hairline).frame(height: 1)
        }
    }

    /// Not a Button: the tag tabs also answer to a double-click, and a Button
    /// next to a rival count-2 gesture doesn't fire until the double-click
    /// interval has run out — a visible stall on every tag switch.
    private func tab(
        title: String,
        selected: Bool,
        action: @escaping () -> Void,
        onRename: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? FlowTheme.ink : FlowTheme.inkSecondary)
            Rectangle()
                .fill(selected ? Color.white : Color.clear)
                .frame(height: 2)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onClick(action, double: onRename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if let onRename { Button("Rename tag", action: onRename) }
        }
    }

    private func name(for mode: TagEditorMode) -> String {
        switch mode {
        case .adding: return ""
        case .renaming(let id): return bridge.notes.tag(id)?.name ?? ""
        }
    }

    /// Empty means "no icon of its own" — the ring falls back to a plain tag
    /// glyph rather than the tag's name.
    private func symbol(for mode: TagEditorMode) -> String {
        switch mode {
        case .adding: return ""
        case .renaming(let id): return bridge.notes.tag(id)?.symbol ?? ""
        }
    }

    /// Nil while adding: there is nothing to delete yet.
    private func deleteAction(for mode: TagEditorMode) -> (() -> Void)? {
        guard case .renaming(let id) = mode else { return nil }
        return {
            // The notes survive and fall back to untagged — see
            // `NotesStore.deleteTag`.
            bridge.notes.deleteTag(id)
            selectedTagID = nil
            tagEditor = nil
        }
    }

    private func save(_ mode: TagEditorMode, named name: String, symbol: String) {
        let symbol: String? = symbol.isEmpty ? nil : symbol
        switch mode {
        case .adding:
            selectedTagID = bridge.notes.addTag(named: name, symbol: symbol).id
        case .renaming(let id):
            bridge.notes.updateTag(id, name: name, symbol: symbol)
        }
        tagEditor = nil
    }
}

/// One text field for adding or renaming a tag. Same draft-then-commit contract
/// as the note editor: nothing reaches the store until Save, Esc cancels.
private struct TagEditorRow: View {
    /// Name and icon, committed together.
    let onSave: (String, String) -> Void
    /// Nil while adding a tag — there is nothing to delete yet.
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var name: String
    @State private var symbol: String
    @State private var hoveringDelete = false
    @FocusState private var focused: Bool

    init(
        initialName: String,
        initialSymbol: String = "",
        onSave: @escaping (String, String) -> Void,
        onDelete: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
        _symbol = State(initialValue: initialSymbol)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SubCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(onDelete == nil ? "New tag" : "Rename tag")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkTertiary)
                        .textCase(.uppercase)
                        .kerning(0.6)
                    Spacer(minLength: 8)
                    // Up here rather than beside Save: a rare, destructive
                    // action, kept quiet and far from the button the hand goes
                    // to after Return. A filled red pill outshouted Save.
                    if let onDelete {
                        Button(action: onDelete) {
                            Text("Delete tag")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(
                                    Color(red: 1.0, green: 0.62, blue: 0.62)
                                        .opacity(hoveringDelete ? 1 : 0.7)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hoveringDelete = $0 }
                    }
                }

                HStack(spacing: 10) {
                    // Sized to what it holds. A tag name is a word, and a
                    // full-width slab promises a paragraph.
                    TextField("Tag name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(width: 220)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(
                                    focused ? FlowTheme.accent.opacity(0.55) : FlowTheme.hairline,
                                    lineWidth: 1
                                )
                        )
                        .focused($focused)
                        .onSubmit { commit() }

                    SecondaryButton(title: "Save", action: commit)
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.45 : 1)
                    RowIconButton(symbol: "xmark", action: onCancel)
                    Spacer(minLength: 0)
                }

                // This is what the ring shows for the tag — the orbit draws the
                // icon, never the name, so it is worth picking one.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ring icon")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.inkSecondary)
                    IconGrid(selection: $symbol, height: 108)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: focused)
        .onAppear { focused = true }
        .onExitCommand { onCancel() }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, symbol)
    }
}


/// A responsive grid of note cards.
///
/// There is no view/edit split: a card *is* its editor, the way Keep, Bear and
/// Notes' gallery all work. That is one state machine fewer than the list this
/// replaced — no `editingID`, no pending-new-row, no separate display row that
/// could disagree with the editor about what a note says.
struct NotesGrid: View {
    @ObservedObject var store: NotesStore
    /// `nil` is the All tab — every note, whatever it is filed under.
    var tagID: UUID?
    @Binding var focusedNoteID: UUID?
    /// Fixed card height for the multi-column page; `nil` where cards stack one
    /// per row and should follow their text.
    var cardHeight: CGFloat? = 186

    /// Most recently edited first, so a just-saved note is where the eye lands.
    private var items: [Note] {
        store.notes(taggedWith: tagID).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Column count follows the window: three across a wide window, one when the
    /// sidebar has squeezed the detail column down.
    private let columns = [GridItem(.adaptive(minimum: 235, maximum: 460), spacing: 14)]

    var body: some View {
        if items.isEmpty {
            SubCard {
                Text(tagID == nil
                     ? "No notes yet. Add one with +, or hold the ring's Note button and pick a tag "
                        + "to keep whatever you have selected."
                     : "Nothing filed here yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Non-lazy in the single-column case, which is the dock: a lazy
            // container needs a bounded viewport to decide what to build, and
            // inside an `NSScrollView`'s document view the height is unbounded
            // — it renders nothing at all. A few dozen cards cost nothing to
            // build eagerly; the multi-column page keeps the lazy grid.
            if cardHeight == nil {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { note in
                        card(for: note)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(items) { note in
                        card(for: note)
                    }
                }
            }
        }
    }

    /// Pulled out of the `LazyVGrid` builder: with this many arguments inline,
    /// the type checker gives up on the whole grid expression.
    private func card(for note: Note) -> some View {
        NoteCard(
            note: note,
            tags: store.tags,
            isFocused: focusedNoteID == note.id,
            onFocusHandled: { focusedNoteID = nil },
            onChange: { title, text in
                store.update(note.id, title: title, text: text)
            },
            onTag: { store.update(note.id, tagID: .some($0)) },
            onToggleContext: {
                store.update(note.id, usedAsContext: !note.usedAsContext)
            },
            onDelete: { store.delete(note.id) },
            fixedHeight: cardHeight
        )
        // Keyed by id alone: re-keying on content would rebuild the card
        // mid-keystroke and drop the caret.
        .id(note.id)
    }
}

/// One note, editable in place.
///
/// Title and body write straight through on every keystroke, exactly as the
/// snippet rows do. That is a full encode + defaults write per character, which
/// is nothing for a few dozen notes.
// ponytail: write-per-keystroke; debounce if someone pastes a novel into one.
private struct NoteCard: View {
    let note: Note
    let tags: [NoteTag]
    let isFocused: Bool
    let onFocusHandled: () -> Void
    let onChange: (String, String) -> Void
    let onTag: (UUID?) -> Void
    let onToggleContext: () -> Void
    let onDelete: () -> Void
    /// A fixed card height keeps every card in a grid *row* the same height.
    /// `nil` drops that and follows the text instead — right wherever the cards
    /// are stacked one per row, like the dock, where uniform height only buys
    /// dead space under short notes.
    let fixedHeight: CGFloat?

    @State private var title: String
    @State private var text: String
    @State private var hovering = false
    @State private var bodyHeight: CGFloat = 0
    @FocusState private var titleFocused: Bool

    /// Floor so an empty note is still a card you can aim at, ceiling so one
    /// long note cannot push every other one off the panel — past it the body
    /// scrolls inside the card, exactly as it does at a fixed height.
    private var contentBodyHeight: CGFloat { min(max(bodyHeight, 34), 260) }

    @ViewBuilder
    private var editor: some View {
        let field = PlainTextEditor(text: $text, measuredHeight: $bodyHeight)
            .onChange(of: text) { _, new in onChange(title, new) }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Write something…")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkTertiary.opacity(0.5))
                        .allowsHitTesting(false)
                }
            }
        if fixedHeight == nil {
            field.frame(maxWidth: .infinity).frame(height: contentBodyHeight)
        } else {
            field.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    init(
        note: Note,
        tags: [NoteTag],
        isFocused: Bool,
        onFocusHandled: @escaping () -> Void,
        onChange: @escaping (String, String) -> Void,
        onTag: @escaping (UUID?) -> Void,
        onToggleContext: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        fixedHeight: CGFloat?
    ) {
        self.note = note
        self.tags = tags
        self.isFocused = isFocused
        self.onFocusHandled = onFocusHandled
        self.onChange = onChange
        self.onTag = onTag
        self.onToggleContext = onToggleContext
        self.onDelete = onDelete
        self.fixedHeight = fixedHeight
        _title = State(initialValue: note.title)
        _text = State(initialValue: note.text)
    }

    private var tagName: String {
        tags.first { $0.id == note.tagID }?.name ?? "No tag"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.ink)
                    .focused($titleFocused)
                    .onChange(of: title) { _, new in onChange(new, text) }
                tagMenu
            }

            // Already an NSScrollView, so a long note scrolls inside its card
            // and every card in a row stays the same height. Flexible rather
            // than fixed: a fixed body inside a fixed card leaves dead space
            // under the last line.
            editor
        }
        .padding(14)
        .frame(height: fixedHeight)
        // One fill, hovered or not. Hover already reveals the tick and the bin
        // below; repainting the whole card on top of that answers "is this
        // clickable" for something that is a page you write on, not a button.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
        // Floated over the card's bottom-right rather than laid out under the
        // body: a row that is invisible most of the time would still reserve
        // its height, which is exactly the gap this replaces.
        .overlay(alignment: .bottomTrailing) { actions }
        .onHover { hovering = $0 }
        .onAppear {
            guard isFocused else { return }
            titleFocused = true
            onFocusHandled()
        }
    }

    /// Which folder the note is in, top-right where a filing label belongs.
    private var tagMenu: some View {
        Menu {
            Button("No tag") { onTag(nil) }
            Divider()
            ForEach(tags) { tag in
                Button(tag.name) { onTag(tag.id) }
            }
        } label: {
            Text(tagName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(note.tagID == nil ? FlowTheme.inkTertiary : FlowTheme.inkSecondary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onToggleContext) {
                Image(systemName: note.usedAsContext ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(note.usedAsContext ? FlowTheme.accent : FlowTheme.inkTertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(note.usedAsContext
                  ? "Gizmos with \"Use my notes\" on can read this note"
                  : "Kept out of every prompt")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete note")
        }
        .padding(12)
        .opacity(hovering ? 1 : 0)
    }
}
