import Foundation

/// Completing a `@tool-name` as it is typed.
///
/// Pure, and separate from the composer that draws the list, because every way
/// this can be wrong is a string question: which `@` is being typed, where the
/// name it started ends, and what the text looks like after a name is picked.
/// A popup is easy to look at and hard to reason about; these are the opposite.
enum ToolMentionCompletion {
    /// A name nobody is going to finish typing. Past this the fragment is prose
    /// that happens to follow an `@`, and offering completions for it is noise.
    static let maximumFragment = 48

    /// The partial name being typed right now, or `nil` when the caret is not
    /// in one.
    ///
    /// Only ever at the end of the text: completion is about what is being
    /// typed, and an `@` earlier in the message is one the user already
    /// finished with. The `@` must also open a word — without that, an email
    /// address opens a tool picker halfway through being typed.
    ///
    /// The fragment runs to the end and may contain spaces, because tool names
    /// do. Nothing needs to guess where a name stops: a fragment that has run
    /// past the real name simply matches nothing and the list goes away.
    static func activeFragment(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let before = text[..<at].last
        guard before == nil || before?.isWhitespace == true else { return nil }
        let fragment = String(text[text.index(after: at)...])
        guard fragment.count <= maximumFragment, !fragment.contains("\n") else { return nil }
        return fragment
    }

    /// Tools whose name the fragment has started. An empty fragment offers
    /// everything, which is what makes a bare `@` a picker rather than a
    /// character you have to guess after.
    static func matches(
        for fragment: String,
        among tools: [GizmateTool],
        limit: Int = 6
    ) -> [GizmateTool] {
        let needle = fragment.lowercased()
        return tools
            .filter { !$0.name.isEmpty }
            .filter { needle.isEmpty || $0.name.lowercased().hasPrefix(needle) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(limit)
            .map { $0 }
    }

    /// The text after picking `tool` from the list.
    ///
    /// Replaces from the `@` to the end, so a half-typed name is not left
    /// behind in front of the full one. The trailing space is what lets the
    /// next word be typed without the composer still thinking a mention is
    /// open — and it is what `ToolChatRouter.mentioned` needs to find a name
    /// that is followed by prose.
    static func completing(_ text: String, with tool: GizmateTool) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@" + tool.name + " "
    }
}
