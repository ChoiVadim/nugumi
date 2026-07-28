import AppKit
import Foundation

/// What is in front of the user at the moment the ring opens. Built once per ring
/// so every trigger test sees the same snapshot, and so the clipboard is read at
/// most once per ring rather than per tool.
///
/// The clipboard is deliberately the universal input channel: ⌘C in Finder puts
/// file URLs on the general pasteboard, so file tools work with no Automation
/// (AppleScript) permission at all. Nothing here is sent anywhere — it only
/// decides which buttons the ring shows until the user picks one.
struct ToolContext: Equatable {
    var selection: String = ""
    var clipboardText: String?
    var clipboardURL: URL?
    var clipboardFiles: [URL] = []

    static let empty = ToolContext()

    /// Reads the current pasteboard. `selection` comes from the presenter, which
    /// already has it armed.
    @MainActor
    static func current(selection: String) -> ToolContext {
        let pasteboard = NSPasteboard.general
        var context = ToolContext(selection: selection.trimmingCharacters(in: .whitespacesAndNewlines))

        // File URLs first: a Finder copy carries both file URLs and a text
        // representation, and the files are the more specific reading.
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL],
           !urls.isEmpty {
            context.clipboardFiles = urls
        }

        let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            context.clipboardText = text
            context.clipboardURL = Self.webURL(from: text)
        }
        return context
    }

    /// A single http(s) URL and nothing else. Deliberately strict: a paragraph
    /// that happens to contain a link is text, not a link, and shouldn't light up
    /// a "download this video" button.
    private static func webURL(from text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else { return nil }
        return url
    }

    /// The argv a tool's declared input resolves to, or nil when the context can't
    /// satisfy it (the runner then reports "nothing to work on" instead of running
    /// a script with no arguments). `.files` yields one entry per file.
    func arguments(for input: ToolInput) -> [String]? {
        switch input {
        case .selection:
            return selection.isEmpty ? nil : [selection]
        case .clipboardText:
            guard let clipboardText, !clipboardText.isEmpty else { return nil }
            return [clipboardText]
        case .clipboardURL:
            guard let clipboardURL else { return nil }
            return [clipboardURL.absoluteString]
        case .files:
            return clipboardFiles.isEmpty ? nil : clipboardFiles.map(\.path)
        case .none:
            return []
        }
    }
}
