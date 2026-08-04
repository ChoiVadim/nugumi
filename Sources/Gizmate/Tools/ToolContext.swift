import AppKit
import Foundation

/// One screen area a tool asked for, already taken.
///
/// Both readings are carried together rather than branching at capture time,
/// because the same drag answers both questions and the tool's declared input
/// decides which one it gets. `text` is empty for a `.screenshot` tool — Vision
/// is only run when someone is going to read the result.
struct ToolScreenshot: Equatable {
    let imageURL: URL
    let text: String
}

/// What a gizmo is handed when it runs. Built per run, not per ring: the two
/// readings that cost something — Finder's selection and the screen capture —
/// only happen for a gizmo that declared it wants them.
struct ToolContext: Equatable {
    var selection: String = ""
    var files: [URL] = []
    /// Set only for a tool whose input needs one, and only after the user has
    /// dragged it out. Nothing captures the screen to build a ring.
    var screenshot: ToolScreenshot?

    static let empty = ToolContext()

    /// `selection` comes from the presenter, which already has it armed. Pass
    /// the running tool's `input` to have the file sources read — without it
    /// nothing asks Finder anything, so a prompt gizmo never trips the
    /// Automation prompt.
    @MainActor
    static func current(
        selection: String,
        screenshot: ToolScreenshot? = nil,
        for input: ToolInput? = nil
    ) -> ToolContext {
        var context = ToolContext(selection: selection.trimmingCharacters(in: .whitespacesAndNewlines))
        context.screenshot = screenshot
        if input?.needsFiles == true {
            context.files = readFiles()
        }
        return context
    }

    /// What Finder has selected, or failing that what was copied out of it.
    /// The fallback is not a nicety: it is the whole file story on a Mac where
    /// the user declined Automation access, and it costs one pasteboard read.
    @MainActor
    private static func readFiles() -> [URL] {
        let selected = FinderSelection.current()
        if !selected.isEmpty { return selected }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let copied = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]
        return copied ?? []
    }

    /// The argv a tool's declared input resolves to, or nil when the context can't
    /// satisfy it (the runner then reports "nothing to work on" instead of running
    /// a script with no arguments). `.files` yields one entry per file.
    func arguments(for input: ToolInput) -> [String]? {
        switch input {
        // `.ask` and `.dictation` ride on `selection` rather than carrying a
        // field of their own: the runner resolves the typed or spoken text
        // before it builds a context and hands it over in exactly the slot a
        // selection would occupy, so a script or prompt downstream cannot tell
        // the three apart. That is the whole point — one argument, however it
        // was produced.
        case .selection, .ask, .dictation:
            return selection.isEmpty ? nil : [selection]
        case .files:
            return files.isEmpty ? nil : files.map(\.path)
        // Both hand over a path: a script cannot be given an image any other
        // way, and the marked-up one is written to disk exactly like a drag.
        case .screenshot, .drawnScreen:
            guard let screenshot else { return nil }
            return [screenshot.imageURL.path]
        case .screenshotText:
            guard let screenshot, !screenshot.text.isEmpty else { return nil }
            return [screenshot.text]
        case .none:
            return []
        }
    }
}
