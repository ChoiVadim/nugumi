import Foundation

/// What Gizmate decided to do about a message, when it decided to do something
/// other than answer it.
enum ToolChatDirective: Equatable {
    /// A new gizmo. The brief is Gizmate's own wording of the request, which is
    /// the whole reason it travels: "yes, do that" is a build request whose
    /// description exists only in the line before it.
    case build(brief: String?)
    /// A change to one that exists.
    case edit(id: UUID)
}

/// Reads Gizmate's own reply for an instruction to the builder.
///
/// There used to be two agents here. One answered the message and one, in
/// parallel, sorted it into talk / build / edit — and because neither could see
/// what the other decided, a message could be answered *and* built. That is not
/// a race that can be tuned out: two models given the same sentence will
/// sometimes disagree, and the user watched Gizmate ask "what shortcut should
/// this use?" while a finished gizmo appeared underneath the question.
///
/// One agent now. Gizmate answers, and when the answer would have been "yes, I
/// can build that", it writes a directive instead of prose. A directive is
/// therefore never in doubt: it is not a guess about what the answer meant, it
/// *is* the answer.
enum ToolChatRouter {
    /// The tool a message names, if it names one.
    ///
    /// Still ahead of the model, and still free. `@Prices` names a tool
    /// outright, so there is nothing to decide and nothing to wait for.
    ///
    /// Longest name first, so a tool called "Price watcher" wins over one
    /// called "Price" for the same `@Price watcher` — matching the shorter one
    /// would silently address the wrong gizmo and leave the rest of the name
    /// sitting in the message as prose. Case-insensitive, because a person
    /// typing a name back is not copying it.
    static func mentioned(in text: String, among tools: [GizmateTool]) -> UUID? {
        let byLength = tools.sorted { $0.name.count > $1.name.count }
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let after = text[text.index(after: at)...].lowercased()
            if let hit = byLength.first(where: {
                !$0.name.isEmpty && after.hasPrefix($0.name.lowercased())
            }) {
                return hit.id
            }
            index = text.index(after: at)
        }
        return nil
    }

    // MARK: - The directive

    private static let build = "BUILD"
    private static let edit = "EDIT"

    /// The two lines that are not prose, and the rules that keep them rare.
    ///
    /// Appended to Gizmate's own voice rather than written into it: this is a
    /// protocol between the chat and the builder, and it has to survive every
    /// future rewrite of how Gizmate talks.
    static let directiveContract = """

        When they want a gizmo built or changed, do not answer in words at all. \
        Reply with exactly one of these lines and nothing else:

        BUILD: <one sentence describing the gizmo, in your own words>
        EDIT: <the exact name of one of their gizmos>

        Rules about those two lines, all of which matter:
        - Never ask them anything about the gizmo first. The builder asks its own questions while it works, and anything you ask here they answer twice.
        - You do not decide whether something can be built, and you are not the one who would find out. Never tell them a request is too complex, too broad, too vague, or not the kind of thing a gizmo is for. When you are unsure it is possible, that is still a BUILD line: the builder either builds it or comes back with the one reason it could not, and both of those beat a guess from you.
        - Never say you are about to build it. The line is the whole reply; the build starts the moment you write it and they watch it happen.
        - Write the description from everything they have told you, not only from the last message. "Yes, do that" is a build request whose description is in the line before it.
        - Never write these lines inside a sentence, never explain them, and never use the words for anything else.
        - The builder cannot see a picture they attached. You can. When a picture is part of what they are asking for, write what it shows into the line itself, because that line is everything the builder gets.
        - The builder is you. When one of your builds stopped without finishing and they say "try again", that is a BUILD line with the same description, not an apology and not a question about what they meant.
        """

    /// The gizmos this person has, so `EDIT` can name one.
    static func knownTools(_ tools: [GizmateTool]) -> String {
        let names = tools.map(\.name).filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return "\n\nThey have no gizmos yet, so EDIT is not possible."
        }
        return "\n\nTheir gizmos: " + names.joined(separator: ", ")
    }

    /// The directive in a finished reply, or `nil` when the reply is an answer.
    ///
    /// A directive owns the first line or it is not one. Anything else is prose,
    /// including an `EDIT` naming a tool that does not exist: the asymmetry is
    /// deliberate, because a missed directive costs the user one more sentence
    /// and an invented one starts writing software nobody asked for.
    static func directive(in reply: String, tools: [GizmateTool]) -> ToolChatDirective? {
        let line = firstLine(of: reply)
        let upper = line.uppercased()
        if upper == build { return .build(brief: nil) }
        if upper.hasPrefix("\(build):") {
            let brief = String(line.dropFirst(build.count + 1))
                .trimmingCharacters(in: .whitespaces)
            return .build(brief: brief.isEmpty ? nil : brief)
        }
        guard upper.hasPrefix("\(edit):") else { return nil }
        let named = String(line.dropFirst(edit.count + 1))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard let hit = tools.first(where: { $0.name.lowercased() == named }) else { return nil }
        return .edit(id: hit.id)
    }

    /// Whether a reply this far in could still turn out to be a directive.
    ///
    /// The reply streams into the transcript as it arrives, and a directive must
    /// never be seen: watching "BUILD: a gizmo that…" type itself out is the
    /// machinery showing through. Six characters settle it, so the answer is
    /// hidden for a few chunks at most and never for a whole reply.
    static func mayBeDirective(_ partial: String) -> Bool {
        let line = firstLine(of: partial).uppercased()
        guard !line.isEmpty else { return true }
        return couldBecome(line, build) || couldBecome(line, edit)
    }

    /// True while `line` is a prefix of the keyword, or the keyword followed by
    /// the colon that makes it one. `BUILDINGS are expensive` is neither, and
    /// must start showing itself the moment the `I` arrives.
    private static func couldBecome(_ line: String, _ keyword: String) -> Bool {
        if line.count < keyword.count { return keyword.hasPrefix(line) }
        guard line.hasPrefix(keyword) else { return false }
        let rest = line.dropFirst(keyword.count)
        return rest.isEmpty || rest.hasPrefix(":")
    }

    private static func firstLine(of text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
