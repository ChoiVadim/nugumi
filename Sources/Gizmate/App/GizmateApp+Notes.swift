import AppKit
import Foundation

extension GizmateApp {
    /// The ring's built-in Note button: keeps the selected text as a note.
    ///
    /// `text` is the ring's armed selection. Empty means the quick menu opened
    /// its ring before anything was read — the same contract every other
    /// built-in action follows, so the read happens here instead.
    @MainActor
    func saveSelectionToNote(_ text: String, tag: NoteTag? = nil) {
        let armed = TextNormalizer.cleanedSelection(text)
        guard armed.isEmpty else {
            keepNote(armed, tagID: tag?.id)
            return
        }

        guard accessibilityIsTrusted() else {
            requestAccessibilityPermissionInteractively()
            return
        }
        // Same settle delay the other selection paths use: the ring click has to
        // land before the AX read, or the selection is still in flux.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.selectionReader.readSelectedTextContext(allowClipboardFallback: true) { [weak self] context in
                guard let self else { return }
                let read = TextNormalizer.cleanedSelection(context?.text ?? "")
                guard !read.isEmpty else {
                    self.presentSelectionTranslationError(
                        "Select some text first, then keep it as a note."
                    )
                    return
                }
                self.keepNote(read, tagID: tag?.id)
            }
        }
    }

    /// Saves and says so. Untitled on purpose: the user is mid-flow in another
    /// app with nothing to type a title into, and `Note.displayTitle` stands the
    /// first line up as one until they give it a real one.
    ///
    /// The toast names the tag rather than the note, because the tag is the part
    /// the user just chose and the only part they could have got wrong.
    @MainActor
    func keepNote(_ text: String, title: String = "", tagID: UUID? = nil) {
        notesStore.add(title: title, text: text, tagID: tagID)
        let tagName = notesStore.tag(tagID)?.name
        ToastHUD.shared.show(text: tagName.map { "Saved to \($0)" } ?? "Saved to notes")
    }

    /// Where a gizmo's note lands when nothing chose a tag for it. Nil once the
    /// user has deleted that tag, which files the note untagged — still visible
    /// under All.
    @MainActor
    var gizmoNoteTagID: UUID? {
        notesStore.tag(NoteTag.otherID)?.id
    }
}
