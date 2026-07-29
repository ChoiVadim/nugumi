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
        "circle.hexagonpath", "circle.circle", "circle.grid.2x2",
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

    /// Browse order: the curated shelf first, then everything else. The shortlist
    /// is a starting shelf, not a ceiling — scrolling past it keeps going into the
    /// full catalog instead of dead-ending.
    static let browsable: [String] = {
        let shelf = Set(curated)
        return curated + all.filter { !shelf.contains($0) }
    }()

    /// A symbol name as something to read rather than something to type.
    ///
    /// SF Symbol names are dotted lowercase identifiers — `arrow.down.circle`,
    /// `bubble.left.and.bubble.right` — which is right for code and wrong in a
    /// settings panel, where it reads as a leaked implementation detail. The
    /// dots are word breaks, so removing them is most of the job.
    ///
    /// Deliberately generic rather than a lookup table. AppKit exposes no
    /// human-readable name for a symbol, and the picker searches all eight
    /// thousand of them, so any name can end up here — a hand-written dictionary
    /// would cover the shortlist, rot as Apple adds glyphs, and still fall back
    /// to this for everything else. Glued compounds like `archivebox` stay glued
    /// ("Archivebox"), which is imperfect and still far better than the raw
    /// identifier.
    static func displayName(for symbolName: String) -> String {
        let words = symbolName
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return symbolName }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    /// What the grid shows. An empty query browses the catalog curated-first; any
    /// query searches all of it.
    ///
    /// Matching splits on dots as well as spaces, so "down arrow" finds
    /// `arrow.down.circle` and every term has to appear.
    static func matching(_ query: String) -> [String] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "." })
            .map(String.init)
        guard !terms.isEmpty else { return browsable }
        return all.filter { name in
            let haystack = name.lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}
