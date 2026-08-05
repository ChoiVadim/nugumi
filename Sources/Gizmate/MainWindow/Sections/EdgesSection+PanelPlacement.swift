import SwiftUI

/// The "Panel placement" list: everything whose result panel can dock but
/// that is never a resident — a `dockableBuiltIns` ring action with no
/// waiting surface (Explain, Reply, Summarize; `saveNote` already has a
/// resident row in `EdgesSection.swift`, same id), and every usable gizmo
/// whose output is `.panel`. None of these ever draws anything before it
/// runs, so DESIGN.md §11's rule that a result panel is not a resident rules
/// out a card row for any of them — a plain `DockPlacementPicker` per row is
/// the whole of what this file adds to `EdgesSectionContent`.
///
/// Split out of `EdgesSection.swift` (Task 3 fix round 1): this concern
/// never needs `residents`, `unplaced`, or the drag machinery declared
/// there, and vice versa — the only thing shared is `cardHeading`, which is
/// why that one symbol is `internal` there instead of `private`.
extension EdgesSectionContent {
    /// Built by filtering down to exactly `EdgesSection.panelPlaceableIDs`
    /// rather than re-deriving the same eligibility rule a second time — the
    /// id set a parity test can check and the rows this list actually draws
    /// are the same computation read twice, so they cannot drift apart the
    /// way the resident list and its old editors once did.
    private var panelPlaceables: [PanelPlaceable] {
        let ids = EdgesSection.panelPlaceableIDs(host: host)
        let builtIns = DockCatalog.dockableBuiltIns
            .filter { ids.contains(ToolRef.builtIn($0).storageID) }
            .map { action in
                PanelPlaceable(
                    id: ToolRef.builtIn(action).storageID,
                    title: overrides.displayName(for: action),
                    icon: overrides.icon(for: action)
                )
            }
        let gizmos = tools.usableTools()
            .filter { ids.contains(ToolRef.generated($0.id).storageID) }
            .map { tool in
                PanelPlaceable(
                    id: ToolRef.generated(tool.id).storageID,
                    title: tool.name,
                    icon: .symbol(tool.resolvedSymbolName)
                )
            }
        return (builtIns + gizmos)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Called from `EdgesSectionContent.body` in `EdgesSection.swift`, which
    /// is why this one is `internal` rather than `private` like the rest of
    /// this file.
    var panelPlacementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeading("Panel placement")
            Text("These don't wait on the edge — they still run from the Ring. Choosing an "
                + "edge here only changes where the answer opens, instead of floating at the cursor.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let rows = panelPlaceables
            if rows.isEmpty {
                SubCard {
                    Text("Nothing placeable here yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                SubCard {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, ref in
                            if index > 0 { Divider().background(FlowTheme.hairline) }
                            panelPlaceableRow(ref)
                        }
                    }
                }
            }
        }
    }

    private func panelPlaceableRow(_ ref: PanelPlaceable) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ref.icon.image(pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 18)
            Text(ref.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
            Spacer(minLength: 12)
            DockPlacementPicker(store: dock, itemID: ref.id)
        }
        .padding(.vertical, 9)
    }
}

/// Title and icon for something whose result panel can dock but that is
/// never a resident — enough to draw a row, unlike `DockItem` which also
/// carries a view this list never instantiates. See `panelPlaceables`.
private struct PanelPlaceable: Identifiable {
    let id: String
    let title: String
    let icon: RingIconKind
}

extension EdgesSection {
    /// Every id the "Panel placement" list will ever offer a picker for:
    /// ring actions in `dockableBuiltIns` that aren't already resident
    /// (their picker is the edge card/"Not on an edge" list instead, same
    /// id), and every usable gizmo whose output is the other member of
    /// `ToolEditorPanel.outputsWithPlacementControl` beyond `.surface`
    /// (already a resident, covered there too). Derived from those four live
    /// sets rather than a literal `[.explain, .reply, .summarize]` or
    /// `.panel`, so a future change to any of them is what this stays
    /// honest about, not a snapshot of today's values.
    ///
    /// Exposed so `DockPlacementParityTests` can hold this against what
    /// `BuiltInEditor` and `ToolEditorPanel` actually point a user at — the
    /// same shape `offeredIDs` gives the resident list. This is the fix for
    /// the gap the review round after Task 3 found: `panelOnlyBuiltIns` and
    /// `panelOnlyGizmos` used to be two hand-written filters nothing held
    /// against the editors' own gates, so a future drift between them would
    /// have shipped a pointer that says "Change it in Edges" pointing at
    /// nothing.
    static func panelPlaceableIDs(host: any SettingsHost) -> Set<String> {
        let builtIns = DockCatalog.dockableBuiltIns
            .filter { !DockCatalog.residentBuiltIns.contains($0) }
            .map { ToolRef.builtIn($0).storageID }
        let gizmoOutputs = ToolEditorPanel.outputsWithPlacementControl
            .subtracting(DockCatalog.dockableGizmoOutputs)
        let gizmos = host.tools.usableTools()
            .filter { gizmoOutputs.contains($0.output) }
            .map { ToolRef.generated($0.id).storageID }
        return Set(builtIns).union(gizmos)
    }
}
