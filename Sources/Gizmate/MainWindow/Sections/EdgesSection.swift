import SwiftUI

/// One picture of one screen: `EdgesDiagram`, plus the sentence that has to sit
/// next to whatever chooses an edge.
///
/// This screen answers exactly one question — *what waits on my screen edges,
/// and in what order*. It used to answer two, and the second one is why it read
/// as five lists for three places: a "Panel placement" card chose where a
/// result panel *opens*, which is a property of one tool that never shares an
/// edge with anything and has no order to be arranged in. That card is gone;
/// its picker went back to `ToolEditorPanel` and `BuiltInEditor`, gated by
/// `PanelPlacement`. See DESIGN.md §11.
struct EdgesSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        // `host` is only nil for the instant between the window opening and
        // `GizmateApp` finishing its own setup.
        if let host = bridge.host {
            EdgesSectionContent(
                dock: bridge.dock,
                tools: bridge.tools,
                overrides: bridge.builtInOverrides,
                host: host
            )
        }
    }
}

/// Split from `EdgesSection` so the stores it reads can be `@ObservedObject`
/// — `GizmateSettingsBridge` holds them but never forwards their own
/// publishers, the same reason `NotesGrid` and `DockPlacementPicker` take
/// their store as a parameter instead of reading it off the bridge.
struct EdgesSectionContent: View {
    @ObservedObject var dock: DockStore
    // Neither is read by name below — `DockCatalog.all(host:)` reaches into
    // both through `host` itself. They're still held as `@ObservedObject`
    // purely so a gizmo being added/renamed or a built-in being renamed
    // triggers a re-render.
    @ObservedObject var tools: ToolsStore
    @ObservedObject var overrides: BuiltInOverridesStore
    let host: any SettingsHost

    var body: some View {
        DetailCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                EdgesDiagram(dock: dock, residents: DockCatalog.all(host: host))
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Edges")
                .font(FlowTheme.serif(30))
                .foregroundStyle(FlowTheme.ink)
            Text("Drag a tool onto an edge. The sides hold several, the top holds one.")
                .font(.system(size: 14))
                .foregroundStyle(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 38)
        .padding(.top, 38)
        .padding(.bottom, 20)
    }

    // No consent footnote here. DESIGN.md §11's rule — approving "run once" is
    // not approving "run again on every hover, forever" — still holds, but a
    // paragraph under the figure said it about every resident on screen when it
    // is only ever true of a gizmo: Note and the folder hub run no script at
    // all. It lives on `ToolEditorPanel`'s Edge hint instead, on the one tool
    // it is actually about, where a person is already reading about that tool.
}

extension EdgesSection {
    /// Every id the figure will ever draw a tile for — exactly the resident set
    /// (`DockCatalog.knownIDs`), never the wider `DockCatalog.placeableIDs`.
    ///
    /// The wide set exists for `prune`, which must not drop a docked `.panel`
    /// tool's placement just because a panel draws nothing while idle. That
    /// answers "whose placement is worth keeping", not "what can sit on an
    /// edge": building the figure off it put a tile — and therefore a working-
    /// looking edge — in front of a `.replace`/`.notify`/`.notes`/`.speak`
    /// gizmo that, once placed, draws nothing anywhere. Exposed rather than
    /// kept private so `DockPlacementParityTests` can hold it against the live
    /// catalog directly.
    static func offeredIDs(host: any SettingsHost) -> Set<String> {
        DockCatalog.knownIDs(host: host)
    }

    /// The one built-in dock resident with no `RingActionID` to name it — the
    /// folder hub (see `DockCatalog.builtIns`'s doc comment on why it has
    /// none). Nothing in this file's UI reads it any more: the figure draws
    /// every resident the same way, so the hub needs no special case to be
    /// reachable. `DockPlacementParityTests` still holds it, together with
    /// `dockableBuiltIns` mapped to ring-action ids, against every id
    /// `DockCatalog.builtIns(host:)` actually returns — that test is asking
    /// "can a user find where this thing lives", and the hub is still the one
    /// resident with no editor of its own to answer from.
    static let residentWithoutARingSlot = ToolRef.folderHub.storageID

    /// The top rail holds exactly one resident, so a drop there evicts whoever
    /// was on it rather than queueing behind them.
    ///
    /// The cap lives here and not in `DockStore` because `placement[.top]`
    /// carries two different meanings in one array: residents that wait on the
    /// edge, and ids whose *result panel* merely opens there. Only the first
    /// kind is capped — `EdgeDockController.dockItems()` resolves through
    /// `DockCatalog.item` and never draws the second — so a cap enforced in the
    /// store would evict a placement it was never about. `residentIDs` is what
    /// tells the two apart, which is why it is a parameter rather than
    /// re-derived: the store has no way to compute it.
    ///
    /// This is also not a new rule, only a stored one. `EdgeDockController`
    /// already expands straight to `items[0]` on hover — the top dock has no
    /// tab strip — so anything a user dropped up there after the first was
    /// saved and never shown again.
    @MainActor
    static func placeOnTop(_ droppedID: String, dock: DockStore, residentIDs: Set<String>) {
        for existing in dock.items(on: .top) where existing != droppedID && residentIDs.contains(existing) {
            dock.dock(existing, to: nil)
        }
        dock.move(droppedID, to: .top, at: 0)
    }

    /// Where a drag onto a rail tile lands, pulled out of the view so a test
    /// can drive it without rendering one.
    ///
    /// `DockStore.move`'s `index` names a position in the *raw*
    /// `placement[edge]` array — what `dock.items(on:)` returns — and that is
    /// not the same array a rail draws. A rail only draws ids that resolve to a
    /// resident `DockItem`; a `.panel` tool placed on this edge sits in the raw
    /// list with no tile. Indexing into the drawn list and handing that number
    /// to `move` names the wrong slot whenever such an id sits before the drop
    /// target — silently, since a bad-but-in-bounds index just lands somewhere
    /// else rather than failing. Resolving `targetID`'s own position in the raw
    /// list, fresh at drop time, is what keeps the two in one coordinate space.
    @MainActor
    static func moveOntoResident(_ droppedID: String, target targetID: String, edge: DockEdge, dock: DockStore) {
        guard let rawIndex = dock.items(on: edge).firstIndex(of: targetID) else { return }
        dock.move(droppedID, to: edge, at: rawIndex)
    }

    /// Where a drag onto the empty part of a rail lands — same raw-list rule as
    /// `moveOntoResident`, using the raw count rather than however many tiles
    /// this rail happens to be drawing.
    @MainActor
    static func moveToEnd(_ droppedID: String, edge: DockEdge, dock: DockStore) {
        dock.move(droppedID, to: edge, at: dock.items(on: edge).count)
    }
}
