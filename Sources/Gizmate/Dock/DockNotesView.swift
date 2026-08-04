import SwiftUI

/// Notes, sized for a dock rather than a settings window.
///
/// `NotesSection` as a whole cannot be reused: it is built around
/// `DetailContainer` with a title, subtitle, pinned tag bar and a `PageBanner`,
/// which in a 360pt panel is a screenful of chrome before the first note. The
/// part that matters — `NotesGrid` and its cards — is reused verbatim, so a note
/// looks and edits the same on an edge as it does on the page.
///
/// No "all notes" link: the dock holds the whole list already, and a button that
/// only swaps which window you read it in is a row of chrome per panel.
struct DockNotesView: View {
    /// The app's one `NotesStore`, handed in rather than reached for through
    /// `GizmateSettingsBridge`: that bridge belongs to the main window and dies
    /// with it, and a dock outlives the main window by design.
    @ObservedObject var notes: NotesStore

    /// `nil` is All. Holding the tag's id rather than an index keeps the
    /// selection pointing at the same tag when tags are added or removed —
    /// the same reasoning `NotesSection` uses.
    @State private var selectedTagID: UUID?
    @State private var draft: String = ""
    /// Handed to `NotesGrid` so a just-saved note opens with the caret in it.
    @State private var focusedNoteID: UUID?

    private var tags: [NoteTag] { notes.tags }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            composer
            if !tags.isEmpty { tagChips }
            Divider().background(FlowTheme.hairline)
            noteList
        }
        .padding(14)
        .foregroundStyle(FlowTheme.ink)
    }

    // MARK: - Composer

    /// Two lines tall from the start, so a note that runs on has somewhere to go
    /// without the box jumping as the first line wraps.
    ///
    /// Return saves, Shift+Return breaks the line — the same pair the gizmo
    /// builder's composer uses, and the same workaround: an `NSTextField`'s
    /// field editor binds Shift+Return to `insertNewline:`, which *ends* editing,
    /// so it has to be routed to the line-break command by hand.
    private var composer: some View {
        TextField("Write a note", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            // `reservesSpace` only exists on the single-Int overload, so the two
            // empty lines are held open by `minHeight` below instead.
            .lineLimit(2...6)
            .onKeyPress(.return, phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                        return .ignored
                    }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                saveDraftAndFocus()
                return .handled
            }
            .foregroundStyle(FlowTheme.ink)
            .padding(.leading, 11)
            .padding(.vertical, 9)
            .padding(.trailing, 38)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(FlowTheme.subtleFill)
            )
            .overlay(alignment: .bottomTrailing) {
                Button(action: saveDraftAndFocus) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(FlowTheme.raisedStrong))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.35)
                .padding(7)
            }
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Tags

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(symbol: "tray.full", title: "All", id: nil)
                ForEach(tags) { tag in
                    chip(symbol: tag.ringSymbol, title: tag.name, id: tag.id)
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private func chip(symbol: String, title: String, id: UUID?) -> some View {
        let selected = selectedTagID == id
        return Button {
            selectedTagID = id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? FlowTheme.ink : FlowTheme.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? FlowTheme.raised : FlowTheme.subtleFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    /// The real note cards, not a stripped-down list. `NotesGrid` lays out with
    /// `.adaptive(minimum: 235)`, so at a dock panel's width it already collapses
    /// to a single column — the same cards as the Notes page, one per row, with
    /// no second implementation to keep in step.
    private var noteList: some View {
        ScrollView {
            // `cardHeight: nil` — one card per row here, so a fixed height only
            // buys dead space under a two-word note.
            NotesGrid(
                store: notes,
                tagID: selectedTagID,
                focusedNoteID: $focusedNoteID,
                cardHeight: nil
            )
            .padding(.bottom, 4)
            // Thin, overlay, auto-hiding — the app's one scroller look, and the
            // only way to get it when macOS is set to "always show scroll bars".
            .background(ScrollerConfigurator())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func saveDraftAndFocus() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focusedNoteID = notes.add(text: text, tagID: selectedTagID).id
        draft = ""
    }

}
