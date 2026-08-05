import SwiftUI

/// Notes, sized for a dock rather than a settings window.
///
/// `NotesSection` as a whole cannot be reused: it is built around
/// `DetailContainer` with a title, subtitle and a pinned tag bar, which in a
/// 360pt panel is a screenful of chrome before the first note. The
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
    /// Handed to `NotesGrid` so a just-added note opens with the caret in it.
    @State private var focusedNoteID: UUID?

    private var tags: [NoteTag] { notes.tags }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().background(FlowTheme.hairline)
            noteList
        }
        .padding(14)
        .foregroundStyle(FlowTheme.ink)
    }

    // MARK: - Tags

    /// Tag chips, then the + that adds a note — the same button the Notes page
    /// header carries, doing the same thing. No composer: the card is already an
    /// editor, so a separate box to type into before the card exists is a second
    /// way to write the same note, one of them without the tag picker or tick.
    private var header: some View {
        HStack(spacing: 8) {
            if !tags.isEmpty { tagChips }
            Spacer(minLength: 0)
            // No hover label: it is drawn beside the disc and would land on the
            // chips. The panel is 360pt wide, not a page header with room.
            ResetDiscButton(symbol: "plus", label: "", accessibilityTitle: "Add note") {
                focusedNoteID = notes.add(tagID: selectedTagID).id
            }
        }
    }

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
    /// `OverlayScrollHost` rather than a SwiftUI `ScrollView`: this is a
    /// borderless panel, where AppKit reverts a set-by-property overlay scroller
    /// back to the wide legacy one. See its doc comment.
    private var noteList: some View {
        OverlayScrollHost {
            // `cardHeight: nil` — one card per row here, so a fixed height only
            // buys dead space under a two-word note.
            NotesGrid(
                store: notes,
                tagID: selectedTagID,
                focusedNoteID: $focusedNoteID,
                cardHeight: nil
            )
            // Clear of the overlay scroller, which floats over the content.
            .padding(.trailing, 4)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
