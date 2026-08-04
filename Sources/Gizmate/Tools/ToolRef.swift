import Foundation

/// What every store keys a tool by, whether it shipped with the app or the user
/// built it.
///
/// `DockStore` already keyed on `String` so a built-in and a gizmo could share
/// one table; this is that instinct made explicit, and it is what lets the
/// shortcut keys join them.
enum ToolRef: Hashable {
    case builtIn(RingActionID)
    case generated(UUID)

    /// Stable across launches. Prefixed so the two namespaces cannot collide —
    /// a gizmo whose UUID somehow read as "dictate" is not the Dictate built-in.
    var storageID: String {
        switch self {
        case .builtIn(let id): return "builtin.\(id.rawValue)"
        case .generated(let id): return "tool.\(id.uuidString)"
        }
    }

    init?(storageID: String) {
        if storageID.hasPrefix("builtin."),
           let id = RingActionID(rawValue: String(storageID.dropFirst("builtin.".count))) {
            self = .builtIn(id)
        } else if storageID.hasPrefix("tool."),
                  let id = UUID(uuidString: String(storageID.dropFirst("tool.".count))) {
            self = .generated(id)
        } else {
            return nil
        }
    }

    /// Which tool's placement applies to a run in this mode.
    ///
    /// A revise is a follow-up inside a panel that is already open, so it
    /// inherits rather than choosing again — and the two summarize modes are the
    /// one built-in, whichever surface asked for it.
    @MainActor
    static func forMode(_ mode: TranslationMode) -> ToolRef? {
        switch mode {
        case .selection: return .builtIn(.explain)
        case .draftMessage, .smartReply: return .builtIn(.reply)
        case .summarizeChat, .summarizePage: return .builtIn(.summarize)
        case .custom(let tool): return .generated(tool.id)
        case .revise, .reviseMessage: return nil
        }
    }

    /// Maps a key written before this type existed.
    ///
    /// The dock shipped with `"notes"` for the notes list and bare UUID strings
    /// for gizmos. The notes list is now the Note built-in's own surface, so
    /// that key lands there rather than being dropped — a user who docked their
    /// notes keeps them docked across the upgrade.
    ///
    /// Anything already in the new form, or in no form this build recognises, is
    /// returned untouched: `DockStore` drops unresolvable ids at read time.
    static func migratedID(from legacy: String) -> String {
        if ToolRef(storageID: legacy) != nil { return legacy }
        if legacy == "notes" { return ToolRef.builtIn(.saveNote).storageID }
        if let id = UUID(uuidString: legacy) { return ToolRef.generated(id).storageID }
        return legacy
    }
}
