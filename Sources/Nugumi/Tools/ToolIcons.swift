import AppKit
import Foundation

/// Icons a tool can wear.
///
/// Two lists, for two different consumers:
///
/// - `curated` is a small hand-picked set. It opens the picker (a wall of eight
///   thousand glyphs isn't a choice, it's a search problem) and it is the ONLY
///   list the generator sees — a prompt can't carry the whole catalog, and it
///   doesn't need to.
/// - `all` is every SF Symbol the running OS ships, read from CoreGlyphs. That is
///   what the picker searches, so the user is never held to the shortlist.
enum ToolIcons {
    /// Used for a brand-new tool, and whenever a saved symbol name no longer
    /// resolves on this OS version.
    static let fallback = "sparkles"

    static let curated: [String] = [
        // Text and language
        "sparkles", "text.alignleft", "text.quote", "textformat", "textformat.abc",
        "character.book.closed", "quote.bubble", "bubble.left.and.bubble.right",
        "abc", "text.badge.checkmark",
        // Thinking and explaining
        "lightbulb", "brain", "questionmark.circle", "book", "graduationcap",
        "magnifyingglass", "eye", "sparkle.magnifyingglass",
        // Structure and data
        "curlybraces", "list.bullet", "list.number", "tablecells", "chart.bar",
        "function", "number", "calendar", "clock",
        // Editing and cleanup
        "wand.and.stars", "scissors", "arrow.triangle.2.circlepath", "checkmark.seal",
        "eraser", "pencil", "highlighter", "arrow.down.right.and.arrow.up.left",
        // Communication
        "envelope", "paperplane", "arrow.bend.up.left", "phone", "megaphone",
        "person.2", "hand.raised",
        // Files and media — script tools live here, so this group carries the
        // download/convert/extract vocabulary the generator reaches for.
        "arrow.down.circle", "square.and.arrow.down", "square.and.arrow.up",
        "folder", "doc.on.doc", "doc.richtext", "photo", "photo.on.rectangle",
        "film", "play.rectangle", "music.note", "waveform", "speaker.wave.2",
        "camera", "link", "arrow.up.arrow.down", "archivebox",
        // Work and objects
        "briefcase", "doc.text", "tag", "flag", "bookmark", "creditcard",
        "cart", "globe", "map", "airplane", "heart", "star", "bolt", "flame",
    ]

    /// Every symbol name this macOS knows, in Apple's own order. Falls back to
    /// `curated` if CoreGlyphs ever moves or stops being readable — the picker
    /// then still works, with fewer options rather than none.
    static let all: [String] = {
        let path = "/System/Library/CoreServices/CoreGlyphs.bundle"
            + "/Contents/Resources/symbol_order.plist"
        guard let names = NSArray(contentsOfFile: path) as? [String], !names.isEmpty else {
            return curated
        }
        return names
    }()

    /// What the grid shows. An empty query keeps the shortlist — the curated set is
    /// meant to be a decent starting shelf, not a ceiling. Any query searches the
    /// whole catalog.
    ///
    /// Matching splits on dots as well as spaces, so "down arrow" finds
    /// `arrow.down.circle` and every term has to appear.
    static func matching(_ query: String) -> [String] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .map(String.init)
        guard !terms.isEmpty else { return curated }
        return all.filter { name in
            let haystack = name.lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}
