import Foundation

/// Where a gizmo can be put the moment it is saved, offered from the chat.
///
/// Saving used to wipe the transcript and say nothing, and the gizmo landed
/// in Home's list marked "Nowhere". A person who had just watched a build
/// finish was left to discover the Ring and Edges sections on their own,
/// which most never did. The chat is the front door, so the question of where
/// a thing lives is asked at the door, right after it is made.
enum ToolHome: Equatable {
    case ring
    case edge(DockEdge)
    case shortcut
    case nowhere

    /// What the card offers for a gizmo with this output. A resident waits on
    /// an edge, so it is offered the edges; everything else is summoned, so it
    /// is offered the ring and a key. Derived from `DockCatalog`'s live set so
    /// a new dockable output cannot reach the dock and miss the card.
    @MainActor
    static func offered(for output: ToolOutput) -> [ToolHome] {
        if DockCatalog.dockableGizmoOutputs.contains(output) {
            return DockEdge.allCases.map { .edge($0) } + [.nowhere]
        }
        return [.ring, .shortcut, .nowhere]
    }

    var label: String {
        switch self {
        case .ring: return "On the ring"
        case .edge(let edge): return "\(edge.displayName) edge of the screen"
        case .shortcut: return "Behind a keyboard shortcut"
        case .nowhere: return "Not now"
        }
    }

    /// The section that shows this home, for the "Open …" button after placing.
    var section: MainWindowSection? {
        switch self {
        case .ring: return .ring
        case .edge: return .edges
        case .shortcut, .nowhere: return nil
        }
    }

    /// One sentence on how to use the gizmo from here, written from how it
    /// starts (`ToolInput`) and where it now lives.
    /// `ringShortcut` is what opens the ring today, in display form.
    /// `folder` names the orbit when it went into one.
    func howToUse(_ tool: GizmateTool, ringShortcut: String, folder: String? = nil) -> String {
        let trigger: String
        switch self {
        case .ring:
            let inside = folder.map { " inside \($0)" } ?? ""
            trigger = "open the ring (\(ringShortcut)) and pick \(tool.name)\(inside)"
        case .shortcut:
            trigger = "press the key you just recorded"
        case .edge(let edge):
            return "Move the pointer to the \(edge.displayName.lowercased()) edge of the screen and \(tool.name) opens there. Open Edges to change the order."
        case .nowhere:
            return "It is in Home's list, marked Nowhere. Give it a home any time from Ring or Edges, or from its own editor."
        }
        switch tool.input {
        case .selection: return "Select some text, then \(trigger)."
        case .files: return "Select files in Finder, then \(trigger)."
        case .ask: return "\(trigger.prefix(1).uppercased() + trigger.dropFirst()); it asks what you want."
        case .dictation: return "\(trigger.prefix(1).uppercased() + trigger.dropFirst()); it listens and takes what you say."
        case .screenshot, .screenshotText, .drawnScreen:
            return "\(trigger.prefix(1).uppercased() + trigger.dropFirst()); it asks you to mark the part of the screen."
        case .none: return "\(trigger.prefix(1).uppercased() + trigger.dropFirst())."
        }
    }
}

/// The card's two states: the question, then the answer that stays on screen
/// until the next message.
enum ToolPlacementStage: Equatable {
    case choosing(GizmateTool)
    case settled(tool: GizmateTool, note: String, section: MainWindowSection?)
}
