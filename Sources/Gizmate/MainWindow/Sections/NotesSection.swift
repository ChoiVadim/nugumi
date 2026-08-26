import SwiftUI
import UniformTypeIdentifiers

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
    /// Kept in defaults, shared with the dock, so the tab survives a relaunch;
    /// a tag deleted since reads as All.
    @AppStorage(NotesStore.selectedTagKey) private var selectedTagRaw = ""
    private var selectedTagID: UUID? {
        get { UUID(uuidString: selectedTagRaw).flatMap { bridge.notes.tag($0)?.id } }
        nonmutating set { selectedTagRaw = newValue?.uuidString ?? "" }
    }
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
            .plainButton()
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
                        .plainButton()
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

    /// The store's own order: the order they were made, and then whatever
    /// order they were dragged into. Sorting by `updatedAt` put every card the
    /// user was mid-way through typing at the top, so the list rearranged
    /// itself under the pointer while it was being read — and a list you cannot
    /// arrange is one nobody can make mean anything.
    private var items: [Note] {
        store.notes(taggedWith: tagID)
    }

    /// What is being dragged, so a card knows whether the pointer arriving over
    /// it is a reorder. Stale after a cancelled drop, which costs nothing: no
    /// `dropEntered` fires without a drag, and the next drag overwrites it.
    @State private var dragging: UUID?

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
            Group {
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
            // No `.onDrop` on the container itself, however tempting for the
            // gaps: on macOS an outer target for the same type takes every
            // `dropEntered` and the cards under it never hear one.
            .onChange(of: dragging) { _, id in
                guard id != nil else { return }
                // SwiftUI never says when a drag ends anywhere but on a target,
                // and the lifted card is dimmed for as long as `dragging` is set.
                // The button state is the one signal that survives a drag session.
                Task { @MainActor in
                    while dragging != nil, NSEvent.pressedMouseButtons & 1 != 0 {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    dragging = nil
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
            onDelete: { store.delete(note.id) },
            onAttach: { store.attach($0, to: note.id) },
            onRemoveImage: { store.removeImage($0, from: note.id) },
            onOpenImage: { index in
                NoteImagePreview.show(note.images.map(store.imageURL), at: index)
            },
            thumbnail: store.thumbnail,
            onDragStart: {
                dragging = note.id
                return NoteReorderPayload.provider(for: note.id)
            },
            fixedHeight: cardHeight
        )
        // Keyed by id alone: re-keying on content would rebuild the card
        // mid-keystroke and drop the caret.
        .id(note.id)
        // The lifted card leaves a hole, the way an iOS icon does: the copy
        // under the pointer is the card now, and the grid shows where it goes.
        .opacity(dragging == note.id ? 0.25 : 1)
        .onDrop(
            of: [NoteReorderPayload.type],
            delegate: NoteReorderDrop(target: note.id, dragging: $dragging, store: store)
        )
    }
}

/// What a note being reordered puts on the drag pasteboard.
///
/// Deliberately not text. It was `NSItemProvider(object: NSString)`, and a note
/// card is made of an `NSTextField` over an `NSTextView` — both of which are
/// registered drop targets for plain text and both of which sit *in front of*
/// the SwiftUI drop target. So dragging a card over any card, its own included,
/// offered the id to the text view first and it took it: the note filled up
/// with UUIDs, and the reorder never happened.
///
/// `public.data` fixes that at the source rather than by teaching each text
/// view to refuse. No text view registers it, so none of them is a destination
/// for this drag at all and AppKit walks up to the card behind them — which is
/// the target that was wanted the whole time. A declared system type, so it
/// needs no `Info.plist` entry, which a `swift run` build has no way to
/// provide (the trap that left every drag in `EdgesDiagram` inert). Visible to
/// this process only, so a card dragged into another app carries nothing.
enum NoteReorderPayload {
    static let type = UTType.data

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// Reorders on the way past rather than on the drop: the cards shuffle under
/// the pointer as it crosses them, so the list itself is the preview and there
/// is no ghost card to draw or insertion bar to place.
///
/// A plain-text payload rather than a `Transferable` of our own. A custom type
/// has to be declared in an `Info.plist`, which a `swift run` build does not
/// have at all — the same trap that left every drag in `EdgesDiagram` silently
/// doing nothing. The id travels as a string, which the system already knows.
private struct NoteReorderDrop: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let store: NotesStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        // Animated, or the cards teleport and the eye cannot tell which one
        // moved where. The slide is the whole preview.
        MainActor.assumeIsolated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                store.move(dragging, toPositionOf: target)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // The move already happened on the way in; this only ends the gesture.
        dragging = nil
        return true
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
    let onDelete: () -> Void
    /// Pictures arrive three ways — dropped on the card, pasted into its body,
    /// or picked through the clip — and all three land here.
    let onAttach: ([ChatImage]) -> Void
    let onRemoveImage: (UUID) -> Void
    /// Opens the full view, starting at this position in `note.images`.
    let onOpenImage: (Int) -> Void
    let thumbnail: (UUID) -> NSImage?
    /// Starts a reorder drag, from the card's title row.
    ///
    /// Not from the body: that is an `NSTextView`, and it wins any argument
    /// with a SwiftUI gesture wrapped around it — a drag begun there is someone
    /// selecting words, which is what it should be. The title row is the one
    /// part of a card that is chrome rather than content, which is why it is
    /// the part you pick a card up by, the way a window has a title bar.
    let onDragStart: () -> NSItemProvider
    /// A fixed card height keeps every card in a grid *row* the same height.
    /// `nil` drops that and follows the text instead — right wherever the cards
    /// are stacked one per row, like the dock, where uniform height only buys
    /// dead space under short notes.
    let fixedHeight: CGFloat?

    @State private var title: String
    @State private var text: String
    @State private var hovering = false
    @State private var hoveredImage: UUID?
    @State private var bodyHeight: CGFloat = 0
    /// The card's own size on screen, so the drag preview can be the same card
    /// rather than a differently sized copy of it.
    @State private var cardSize: CGSize = .zero
    @FocusState private var titleFocused: Bool

    /// Floor so an empty note is still a card you can aim at, ceiling so one
    /// long note cannot push every other one off the panel — past it the body
    /// scrolls inside the card, exactly as it does at a fixed height.
    private var contentBodyHeight: CGFloat { min(max(bodyHeight, 34), 260) }

    @ViewBuilder
    private var editor: some View {
        let field = PlainTextEditor(text: $text, measuredHeight: $bodyHeight, pasteHook: takePastedPictures)
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
        onDelete: @escaping () -> Void,
        onAttach: @escaping ([ChatImage]) -> Void,
        onRemoveImage: @escaping (UUID) -> Void,
        onOpenImage: @escaping (Int) -> Void,
        thumbnail: @escaping (UUID) -> NSImage?,
        onDragStart: @escaping () -> NSItemProvider,
        fixedHeight: CGFloat?
    ) {
        self.note = note
        self.tags = tags
        self.isFocused = isFocused
        self.onFocusHandled = onFocusHandled
        self.onChange = onChange
        self.onTag = onTag
        self.onDelete = onDelete
        self.onAttach = onAttach
        self.onRemoveImage = onRemoveImage
        self.onOpenImage = onOpenImage
        self.thumbnail = thumbnail
        self.onDragStart = onDragStart
        self.fixedHeight = fixedHeight
        _title = State(initialValue: note.title)
        _text = State(initialValue: note.text)
    }

    /// A transparent sheet over the title, present only while the title is not
    /// being edited.
    ///
    /// It has to be a layer of its own: an `NSTextField` takes the mouse-down
    /// itself, so an `onDrag` on the row around it never fires — the drag would
    /// silently be a text selection instead. Clicking hands focus to the field
    /// and the sheet lifts, so editing a title is unchanged after the first
    /// click; it comes back when focus leaves.
    private var titleDragSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { titleFocused = true }
            .onDrag({
                // Step out of the card first. A caret still sitting in the body
                // makes the thing being carried also the thing being typed in,
                // and the editor under it goes on claiming the pointer.
                titleFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
                return onDragStart()
            }, preview: { dragPreview })
            .cursor(.openHand)
            .help("Drag the title to reorder")
    }

    /// What travels with the pointer: the card, not a glyph. Rebuilt rather than
    /// snapshotted because the live card holds two editors, and a drag preview
    /// made of live text fields is a second caret on screen.
    ///
    /// Sized from the real card so the thing under the pointer is the size of
    /// the hole it left. The fallback only ever shows for a drag begun in the
    /// same frame the card first appeared.
    private var dragPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.isEmpty ? "Untitled" : title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(FlowTheme.ink)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.inkSecondary)
                .lineLimit(6)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(
            width: max(cardSize.width, 235),
            height: max(cardSize.height, 96),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FlowTheme.subtleFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.hairline, lineWidth: 1)
        )
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
                    .overlay { if !titleFocused { titleDragSurface } }
                tagMenu
            }

            if !note.images.isEmpty { pictures }

            // Already an NSScrollView, so a long note scrolls inside its card
            // and every card in a row stays the same height. Flexible rather
            // than fixed: a fixed body inside a fixed card leaves dead space
            // under the last line.
            //
            // The bottom inset is the actions row's height: it floats over
            // this corner, and without the inset the last line of a note sits
            // under the clip and the bin the moment the pointer arrives.
            editor.padding(.bottom, 14)
        }
        .padding(14)
        .frame(height: fixedHeight)
        // The card under the pointer is the note the picture is for, so each
        // card is its own target. Inside the reorder `onDrop` in `NotesGrid`:
        // a file URL conforms to `UTType.data` too, and the deeper target is
        // the one that gets asked first.
        .dropDestination(for: URL.self) { urls, _ in
            let pictures = urls.compactMap(ChatImage.init(contentsOf:))
            guard !pictures.isEmpty else { return false }
            onAttach(pictures)
            return true
        }
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
        // body, so the row can fade without the layout moving; the body keeps
        // the inset above so the two never share a line.
        .overlay(alignment: .bottomTrailing) { actions }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    cardSize = size
                }
            }
        }
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
        .cursor(.pointingHand)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Same rule as the chat's ⌘V (DESIGN.md §17): a picture file is taken
    /// whole, its name being noise; pixels beside real words are taken *and*
    /// the words go on to the editor.
    private func takePastedPictures(_ pasteboard: NSPasteboard) -> Bool {
        let paste = ChatImage.pasted(pasteboard)
        guard !paste.pictures.isEmpty else { return false }
        onAttach(paste.pictures)
        return !paste.keepsText
    }

    /// Thumbnails above the body, wrapping onto new rows; a click opens the
    /// full view, and the cross that fades in on hover removes — the same
    /// treatment as the card's own bin (DESIGN.md §9).
    ///
    /// Wrapped rather than scrolled sideways: a `ScrollView` here took the
    /// wheel from the list of cards around it, so the list stopped wherever
    /// the pointer rested on a picture.
    private var pictures: some View {
        FlowWrap(spacing: 6) {
            ForEach(Array(note.images.enumerated()), id: \.element) { index, id in
                Group {
                    if let image = thumbnail(id) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(FlowTheme.inkTertiary)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onOpenImage(index) }
                .cursor(.pointingHand)
                .overlay(alignment: .topTrailing) {
                    Button { onRemoveImage(id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.55))
                            .contentShape(Rectangle())
                    }
                    .plainButton()
                    .padding(2)
                    .opacity(hoveredImage == id ? 1 : 0)
                    .help("Remove picture")
                }
                .onHover { inside in
                    if inside { hoveredImage = id } else if hoveredImage == id { hoveredImage = nil }
                }
                .contextMenu { Button("Remove picture") { onRemoveImage(id) } }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { onAttach(ChatImage.pick()) } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .contentShape(Rectangle())
            }
            .plainButton()
            .help("Attach a picture. Drop one on the card, or paste it.")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .contentShape(Rectangle())
            }
            .plainButton()
            .help("Delete note")
        }
        .padding(12)
        .opacity(hovering ? 1 : 0)
    }
}
