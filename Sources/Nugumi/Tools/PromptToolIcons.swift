import AppKit
import Foundation

/// The SF Symbols offered in the prompt-tool icon grid. A curated list, not the
/// whole SF Symbols catalog: the grid has to stay scannable, and every glyph
/// here reads correctly as a white template at the ring's 20pt size.
enum PromptToolIcons {
    /// Used for a brand-new tool, and whenever a saved symbol name no longer
    /// resolves on this OS version.
    static let fallback = "sparkles"

    static let all: [String] = [
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
        // Work and objects
        "briefcase", "doc.text", "tag", "flag", "bookmark", "creditcard",
        "cart", "globe", "map", "airplane", "heart", "star", "bolt", "flame",
    ]

    /// Icons whose name contains `query` (case-insensitive), for the grid's
    /// search field. An empty query returns everything.
    static func matching(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.contains(q) }
    }
}
