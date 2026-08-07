import Foundation

/// What one message typed into Home's chat is asking for.
enum ToolChatIntent: Equatable {
    /// A question, answered in the transcript. Nothing is built.
    case talk
    /// A new gizmo.
    case build
    /// A change to one that exists.
    case edit(UUID)
}

/// Decides which of the three a message is.
///
/// Two stages, and the order is the whole design. A mention answers the
/// question outright — `@Prices` names a tool, and nothing a model could say
/// would make that mean something else — so a mentioned message never costs a
/// classification call, never waits on the network, and never gets it wrong.
/// Only an unmentioned message is handed to the model, and the model gets one
/// job with three answers rather than a conversation.
enum ToolChatRouter {
    /// The tool a message names, if it names one.
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

    /// What the model is asked, when nothing was mentioned.
    ///
    /// The tool names go in so `EDIT` can name one: a person who writes "make
    /// the price one check twice a day" has named a gizmo without typing an
    /// `@`, and refusing to understand that would make mentions mandatory
    /// rather than a shortcut.
    static let systemPrompt = """
        You sort one message into exactly one of three kinds. Reply with the kind and nothing else.

        TALK — a question, a request for information, or conversation. Anything the user wants an answer to rather than a tool for.
        BUILD — the user wants a new tool made for them.
        EDIT: <name> — the user wants one of their existing tools changed. Use the tool's exact name from the list.

        When it is not clear, answer TALK. Answering TALK for a build request costs the user one more sentence; answering BUILD for a question makes the app start writing software nobody asked for.
        """

    static func userPrompt(message: String, tools: [GizmateTool]) -> String {
        let names = tools.map(\.name).filter { !$0.isEmpty }
        let list = names.isEmpty
            ? "The user has no tools yet, so EDIT is not possible."
            : "The user's tools: " + names.joined(separator: ", ")
        return "\(list)\n\nMessage:\n\(message)"
    }

    /// Reads the model's answer back.
    ///
    /// Anything unrecognised is `.talk`, and so is an `EDIT` naming a tool that
    /// does not exist. The asymmetry is deliberate and stated in the prompt as
    /// well: a wrong `TALK` costs the user one more sentence, a wrong `BUILD`
    /// starts generating software nobody asked for.
    static func intent(from reply: String, tools: [GizmateTool]) -> ToolChatIntent {
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = clean.uppercased()
        if upper.hasPrefix("BUILD") { return .build }
        guard upper.hasPrefix("EDIT") else { return .talk }
        guard let colon = clean.firstIndex(of: ":") else { return .talk }
        let named = clean[clean.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let hit = tools.first(where: { $0.name.lowercased() == named }) else { return .talk }
        return .edit(hit.id)
    }
}
