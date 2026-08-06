import AppKit

/// The right-click menu on a file card.
///
/// Finder's own menu cannot be borrowed — there is no API that hands it over —
/// so this is the subset a shelf can honestly offer: open it, open it with
/// something else, ask Finder about it, copy it, throw it away.
///
/// Move to Trash was deliberately absent while this was only a hand-off shelf:
/// something whose job is passing files to other apps should not be one stray
/// click from deleting them, and the Finder this menu can already reveal into
/// had the real thing. The folder hub taking drops is what changed it. A place
/// you can put files into and cannot take them out of is a one-way drawer, and
/// the stray-click objection is answered by where it puts them: the Trash, with
/// Put Back intact, not `removeItem`.
///
/// An `NSMenuItem` holds its target weakly, so whoever builds one of these has
/// to keep it alive for as long as the menu can be clicked —
/// `SurfaceCardMouseView.menuTarget` is that owner.
@MainActor
final class FileActionMenu: NSObject {
    private let urls: [URL]
    /// Told when something on disk moved, so whatever is showing these files can
    /// stop showing one that is gone. `nil` on success. Optional because a
    /// surface with no way to refresh is still allowed to offer the menu.
    private let onTrashed: ((Error?) -> Void)?

    init(urls: [URL], onTrashed: ((Error?) -> Void)? = nil) {
        self.urls = urls
        self.onTrashed = onTrashed
    }

    /// `nil` when there is nothing to act on. AppKit takes that as "no menu",
    /// which is the right answer for a card whose row lost its path.
    func makeMenu() -> NSMenu? {
        guard let first = urls.first else { return nil }
        let menu = NSMenu()
        menu.addItem(item("Open" + countSuffix, #selector(openFiles)))
        if let openWith = openWithMenu(for: first) {
            let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            parent.submenu = openWith
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(item("Get Info", #selector(getInfo)))
        menu.addItem(item("Show in Finder", #selector(showInFinder)))
        menu.addItem(.separator())
        menu.addItem(item("Copy", #selector(copyFiles)))
        menu.addItem(.separator())
        // Last, after a separator, and named for the Trash rather than for
        // deleting: the word is the difference between an action with a way
        // back and one without, and this one has a way back.
        menu.addItem(item("Move to Trash" + countSuffix, #selector(trashFiles)))
        return menu
    }

    /// Named for how many files the click is actually about, because a
    /// right-click inside a selection acts on the whole of it — "Open" alone
    /// on a menu that opens nine things is a lie the user finds out after.
    private var countSuffix: String {
        urls.count > 1 ? " \(urls.count) Items" : ""
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Every app macOS would offer for this file — the same list Finder's own
    /// submenu is built from, default handler first. Built from the first file
    /// only: a mixed selection has no common list, and the alternative (the
    /// intersection) is usually empty, which reads as "you can't open these"
    /// rather than "these are different kinds".
    private func openWithMenu(for url: URL) -> NSMenu? {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard !apps.isEmpty else { return nil }
        let menu = NSMenu()
        for app in apps {
            let entry = NSMenuItem(
                title: FileManager.default.displayName(atPath: app.path),
                action: #selector(openWithApp(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            menu.addItem(entry)
        }
        return menu
    }

    // MARK: - Actions

    @objc private func openFiles() {
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// `NSWorkspace.recycle` rather than `FileManager.removeItem`, and the
    /// difference is the whole feature: recycling is Finder's own move, so the
    /// file lands in the Trash with Put Back working and the sound playing.
    /// Deleting would make a right-click one slip away from unrecoverable.
    @objc private func trashFiles() {
        NSWorkspace.shared.recycle(urls) { [onTrashed] _, error in
            Task { @MainActor in onTrashed?(error) }
        }
    }

    @objc private func copyFiles() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Real file URLs, so a paste into Finder is the file and a paste into a
        // text field is its path — the same thing the card's drag hands over.
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// A Get Info window belongs to Finder and no framework opens one, so this
    /// is the second place Gizmate speaks AppleScript (`FinderSelection` is the
    /// first, and it is why the app already asks for Automation access).
    @objc private func getInfo() {
        let statements = urls
            .map { "open information window of (POSIX file \"\(escapedForAppleScript($0.path))\" as alias)" }
            .joined(separator: "\n")
        let source = "tell application \"Finder\"\nactivate\n\(statements)\nend tell"
        // Off the main thread: Finder answers when it feels like it, and a
        // busy one would otherwise freeze the panel mid-click. Nothing comes
        // back — a refused Automation prompt or a missing file is "no window
        // opened", which the user sees for themselves.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    /// A filename is user data on its way into a script. A file called
    /// `pay"day.txt` would otherwise close the string literal and hand the rest
    /// of its own name to Finder as AppleScript to run.
    private func escapedForAppleScript(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
