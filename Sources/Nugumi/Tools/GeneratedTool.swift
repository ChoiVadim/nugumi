import Foundation
import NugumiToolAgentCore

/// A manifest plus script the agent wrote, ready to drop into the editor.
struct GeneratedTool {
    var tool: NugumiTool
    var script: String
    /// One line the model wrote about what the tool does, shown above the code.
    var summary: String
    /// The tool's purpose as one request, rewritten by the model to fold in
    /// whatever was just asked for. Stored on the tool so the next edit starts
    /// from an accurate description instead of the original wording.
    var brief: String
    /// What Gizmo actually proved about this tool before offering it. Shown to
    /// the user, because "verified" and "it at least starts up" are different
    /// promises and only one of them used to be possible.
    var assurance: ToolAgentAssuranceV1 = .verified
}

extension ToolAgentAssuranceV1 {
    /// One sentence for the chat, in the same voice as the rest of the builder.
    var explanation: String {
        switch self {
        case .verified:
            return "I ran it on test input and the output matched."
        case .smoke:
            return "I ran it for real and it finished cleanly."
        case .unverified:
            return "I didn't run it — doing that for real would have had side "
                + "effects. The code compiles and its dependencies resolve."
        }
    }

    /// Short badge text for the summary card.
    var badge: String {
        switch self {
        case .verified: return "Tested"
        case .smoke: return "Ran once"
        case .unverified: return "Not run"
        }
    }
}

enum ToolGeneratorError: LocalizedError {
    case emptyDescription

    var errorDescription: String? {
        switch self {
        case .emptyDescription:
            return "Describe what the tool should do first."
        }
    }
}
