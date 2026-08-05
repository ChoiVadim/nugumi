import Foundation

/// Who gets a `DockPlacementPicker` in their own editor, and who is told to go
/// to Edges instead.
///
/// The two questions are not the same question, which is the whole reason this
/// exists. **Where a result panel opens** is a property of one tool — it draws
/// nothing until that tool runs, it never shares an edge with anything, and
/// there is no order to arrange it in. **Where a resident waits** is a property
/// of the screen: several of them share one edge, in an order only that edge
/// can decide. Edges owns the second and nothing else, so the first goes back
/// to the editor it belongs to.
///
/// This reverses the "placement is written from exactly one screen" rule that
/// `EdgesSection`'s old "Panel placement" card enforced — see DESIGN.md §11 for
/// why the rule was right about residents and wrong about panels.
///
/// Lives in `MainWindow/Core` rather than beside `DockCatalog`: every set it
/// reads is a catalog constant, but the answer it computes is about which
/// *editor* draws a control, and `Dock/` must not have to know that
/// `ToolEditorPanel` exists.
/// `@MainActor` for one reason only: every set it reads is a `DockCatalog`
/// constant, and that whole enum is main-actor isolated.
@MainActor
enum PanelPlacement {
    /// A built-in whose result panel can dock but that never waits on an edge.
    /// Note is the exception the `!residentBuiltIns` filter removes: its notes
    /// list and its panel are one id with one placement, so choosing an edge
    /// for it is choosing where the list *lives*, which is Edges' question.
    static func offersPicker(for action: RingActionID) -> Bool {
        DockCatalog.dockableBuiltIns.contains(action)
            && !DockCatalog.residentBuiltIns.contains(action)
    }

    /// The gizmo half of the same rule: an output `ToolEditorPanel` says
    /// something about that is not one `DockCatalog` will give a waiting tab.
    /// `.panel` is the only member today; `.surface` is the one subtracted.
    static func offersPicker(for output: ToolOutput) -> Bool {
        ToolEditorPanel.outputsWithPlacementControl
            .subtracting(DockCatalog.dockableGizmoOutputs)
            .contains(output)
    }

    /// Every id one of the two predicates above puts a picker in front of.
    ///
    /// Derived from those same two functions rather than re-deriving the rule,
    /// so `DockPlacementParityTests` is checking the editors' real gates and
    /// not a second copy of them — which is exactly how the old
    /// `EdgesSection.panelPlaceableIDs` could drift from what the editors
    /// actually offered.
    static func placeableIDs(host: any SettingsHost) -> Set<String> {
        let builtIns = DockCatalog.dockableBuiltIns
            .filter(offersPicker(for:))
            .map { ToolRef.builtIn($0).storageID }
        let gizmos = host.tools.usableTools()
            .filter { offersPicker(for: $0.output) }
            .map { ToolRef.generated($0.id).storageID }
        return Set(builtIns).union(gizmos)
    }
}
