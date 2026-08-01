import AppKit
import Foundation

/// What is selected in Finder right now.
///
/// This is the one place Gizmate speaks AppleScript, and it is why the app asks
/// for Automation access to Finder. The cheaper trick — reading file URLs off
/// the pasteboard after ⌘C — is still the fallback in `ToolContext`, because it
/// needs no permission at all and works when Finder is not the front app.
enum FinderSelection {
    /// The selected items, or an empty array when Finder has nothing selected,
    /// is not running, or the user declined Automation access. Every one of
    /// those is "no files", not an error: the caller falls back to the
    /// pasteboard and then reports "nothing to work on" like any other input.
    ///
    /// ponytail: blocks the main thread while Finder answers. It is one Apple
    /// event against a local app and only runs when a `files` gizmo starts;
    /// move it off-main if a busy Finder ever makes the ring stutter.
    @MainActor
    static func current() -> [URL] {
        // Asking Finder for POSIX paths rather than aliases: an alias
        // descriptor has to be coerced back to a URL on this side, and a path
        // AppleScript already resolved is one conversion fewer to get wrong.
        let source = """
        tell application "Finder"
            set chosen to selection
            set paths to {}
            repeat with item_ in chosen
                set end of paths to POSIX path of (item_ as alias)
            end repeat
            return paths
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            guard let path = result.atIndex(index)?.stringValue, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}
