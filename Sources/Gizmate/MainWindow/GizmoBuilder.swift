import Foundation
import GizmateToolAgentCore

/// Every gizmo currently being edited or built, and the one build in flight.
///
/// Owned by the app rather than by a view, and that is the whole reason it
/// exists. A build takes minutes and its result lives nowhere else until it is
/// saved, so hanging it off `ToolEditorPanel`'s `@State` meant closing the
/// panel — or, once Home hosted it, merely looking at another section — threw
/// the work away.
///
/// It also settles a question two surfaces would otherwise answer differently.
/// The chat can be changing a gizmo while that gizmo's Details modal is open,
/// and if each held its own copy the second save would quietly overwrite the
/// first. `draft(for:)` memoizes, so there is one draft per gizmo and both
/// surfaces are looking at it.
@MainActor
final class GizmoBuilder: ObservableObject {
    private var drafts: [GizmoDraft.Subject: GizmoDraft] = [:]

    private let tools: ToolsStore
    private let runner: GizmoDraft.Runner

    init(tools: ToolsStore, runner: @escaping GizmoDraft.Runner) {
        self.tools = tools
        self.runner = runner
    }

    /// The draft for this gizmo, made once and kept.
    ///
    /// Identity is what matters here, not the contents: two calls must return
    /// the same object or the two surfaces editing it are editing different
    /// things.
    func draft(for subject: GizmoDraft.Subject) -> GizmoDraft {
        if let existing = drafts[subject] { return existing }
        let made = GizmoDraft(subject: subject, tools: tools, runner: runner)
        drafts[subject] = made
        return made
    }

    /// Throws a draft away once it has been saved or abandoned, cancelling
    /// whatever it still had running. The next `draft(for:)` hydrates a fresh
    /// one from the store, which is what makes a saved gizmo reopen showing
    /// what was saved rather than what was typed before it.
    func discard(_ subject: GizmoDraft.Subject) {
        drafts[subject]?.cancelInFlight()
        drafts[subject] = nil
    }

    /// Whether this gizmo has work in flight, for a control that must not let
    /// someone edit underneath it.
    func isBusy(_ subject: GizmoDraft.Subject) -> Bool {
        drafts[subject]?.isRunning ?? false
    }
}
