import SwiftUI
import UniformTypeIdentifiers

/// One card per screen edge, each listing its residents in tab order, plus
/// every other resident that currently sits on none of them (deliberately
/// "resident", not the wider "placeable" — see `unplaced`'s doc comment).
/// `EdgesSection+PanelPlacement.swift` adds a list for everything placeable
/// that is never a resident at all, and `EdgesSection+FolderHub.swift` adds
/// the folder hub's own setup — both are `extension EdgesSectionContent`,
/// this file's `struct`, split out purely because the three concerns don't
/// need to see each other's internals and together ran past ~400 lines.
///
/// This is now the one place placement is written. `BuiltInEditor`, `ToolEditor`
/// and `SettingsSection`'s General tab each used to carry their own
/// `DockPlacementPicker` writing straight to `DockStore`; all three now hold
/// only a locality pointer back here (see each file's own pointer property),
/// because a gizmo, a built-in and the folder hub all choose an edge through
/// the same store, and three call sites writing to one store was the thing
/// worth collapsing.
struct EdgesSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        // `host` is only nil for the instant between the window opening and
        // `GizmateApp` finishing its own setup — every editor's pointer
        // assumes the same thing and would say nothing rather than guess.
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
///
/// Not `private`: `EdgesSection+PanelPlacement.swift` and
/// `EdgesSection+FolderHub.swift` both extend this type from a different
/// file, which Swift's file-scoped `private` would make impossible to name.
/// Everything on it stays `private` (file-scoped) except `cardHeading`,
/// which both of those files also call — promoted no further than that one
/// symbol needed.
struct EdgesSectionContent: View {
    @ObservedObject var dock: DockStore
    // Neither is read by name below — `DockCatalog.all(host:)` reaches into
    // both through `host` itself. They're still held as `@ObservedObject`
    // purely so a gizmo being added/renamed or a built-in being renamed
    // triggers a re-render; without one, SwiftUI has nothing telling it this
    // view's `body` needs to run again.
    @ObservedObject var tools: ToolsStore
    @ObservedObject var overrides: BuiltInOverridesStore
    let host: any SettingsHost

    /// Resident items only — the same set `EdgeDockController` actually draws
    /// on the physical edge. An id `DockStore` holds that isn't in here (a
    /// deleted gizmo, or a built-in whose panel docks but has no waiting
    /// surface) resolves to nothing and the row is simply skipped, matching
    /// what the real dock already does with it.
    private var residents: [String: DockItem] {
        Dictionary(uniqueKeysWithValues: DockCatalog.all(host: host).map { ($0.id, $0) })
    }

    /// Everything the "not on an edge" list may ever offer a control for —
    /// deliberately `DockCatalog.knownIDs` (the resident set), never
    /// `DockCatalog.placeableIDs`. `placeableIDs` is wider on purpose: `prune`
    /// uses it to avoid dropping a docked `.panel` gizmo's placement even
    /// though a panel draws nothing while idle. That wideness answers "whose
    /// placement is worth keeping", not "what can sit on an edge" — building
    /// this list off it directly offered a working-looking picker for a
    /// `.replace`/`.notify`/`.notes`/`.speak`/`.annotate` gizmo that, once
    /// placed, draws nothing anywhere. `EdgesSection.offeredIDs` (below) is
    /// the same expression, exposed so a parity test can hold it against the
    /// live catalog directly. `EdgesSection+PanelPlacement.swift`'s list is
    /// where a `.panel` gizmo and a panel-only built-in get their picker
    /// instead — they are placeable but never resident, so they don't
    /// belong in this list.
    private var unplaced: [DockItem] {
        let placed = Set(DockEdge.allCases.flatMap { dock.items(on: $0) })
        let residents = residents
        return EdgesSection.offeredIDs(host: host)
            .subtracting(placed)
            .compactMap { residents[$0] }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// `DockPlacementPicker`'s `nil` label isn't one word for every resident
    /// — DESIGN.md §11 is explicit that a surface (and the folder hub, the
    /// same shape) has no floating form, so `nil` there means "saved and
    /// inert" rather than "works, just not docked". `ToolRef` already tells
    /// the two apart: of the three kinds `residents` can ever hold, only a
    /// `.builtIn` (Note, today the one ring resident) still works floating —
    /// `.folderHub` and every `.generated` id here are `.surface` gizmos by
    /// construction of `DockCatalog.gizmos`' own filter.
    private func unplacedLabel(for item: DockItem) -> String {
        if case .builtIn = ToolRef(storageID: item.id) { return "Floating" }
        return "Off"
    }

    /// The spec's consent line, said exactly once, right next to the picker
    /// that actually makes the choice — DESIGN.md §11. Only the two resident
    /// kinds with no floating form need it, the same two `unplacedLabel`
    /// above already calls "Off" instead of "Floating". The two sentences are
    /// deliberately different wordings of different facts, not one sentence
    /// reused: a surface gizmo runs a script on every hover a user never
    /// approved happening again; the folder hub only reads `FileManager` on
    /// every hover, which was never a thing to approve in the first place.
    /// Flattening the two into one sentence would make a false claim about
    /// whichever resident borrowed the other's wording.
    private func consentSentence(for item: DockItem) -> String? {
        if item.id == EdgesSection.residentWithoutARingSlot {
            return "It only reads the folder — there's nothing to run or approve. "
                + "Off keeps it saved but out of sight."
        }
        if case .generated = ToolRef(storageID: item.id) {
            return "This gizmo runs on its own, whenever its edge opens — docking it "
                + "here is what turns that on. Leave it off and it stays saved but never runs."
        }
        return nil
    }

    var body: some View {
        DetailContainer(
            "Edges",
            subtitle: "What waits on a screen edge, and in what order."
        ) {
            ForEach(DockEdge.allCases, id: \.self) { edge in
                edgeCard(edge)
            }
            unplacedCard
            panelPlacementCard
            // No folder-hub setup here. Which folders the hub shows is a
            // setting of one resident, and a resident configures itself in its
            // own panel — the hub's chip row and `+` already do exactly this
            // where the folders are visible. This screen decides *where things
            // sit*, which is the one question no single tool can answer alone.
        }
    }

    // MARK: - Edge cards

    private func edgeCard(_ edge: DockEdge) -> some View {
        let residents = residents
        let items = dock.items(on: edge).compactMap { residents[$0] }
        return VStack(alignment: .leading, spacing: 10) {
            cardHeading(edge.displayName)
            if items.isEmpty {
                SubCard {
                    Text("Nothing docked here.")
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The only drop target an empty card needs — there is no row
                // to drop onto, so the whole card stands in for one. Routed
                // through `moveToEnd` rather than a literal `0`: the card can
                // render empty while the edge's raw list isn't (a docked
                // Explain, say, has nothing to draw here) — appending keeps
                // that invisible entry's position untouched either way.
                .dropDestination(for: EdgeResidentDrag.self) { drags, _ in
                    guard let dragged = drags.first else { return false }
                    EdgesSection.moveToEnd(dragged.id, edge: edge, dock: dock)
                    return true
                }
            } else {
                SubCard {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().background(FlowTheme.hairline) }
                            EdgeResidentRow(
                                item: item,
                                onDropped: { droppedID in
                                    EdgesSection.moveOntoResident(droppedID, target: item.id, edge: edge, dock: dock)
                                }
                            )
                        }
                        // A trailing drop target the size of a row's padding —
                        // without it, nothing lets a drag land after the last
                        // resident short of dropping past the card entirely.
                        EdgeAppendDropZone { droppedID in
                            EdgesSection.moveToEnd(droppedID, edge: edge, dock: dock)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Unplaced

    private var unplacedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeading("Not on an edge")
            let rows = unplaced
            Group {
                if rows.isEmpty {
                    SubCard {
                        Text("Everything that can sit on an edge is already there.")
                            .font(.system(size: 13))
                            .foregroundStyle(FlowTheme.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    SubCard {
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, ref in
                                if index > 0 { Divider().background(FlowTheme.hairline) }
                                unplacedRow(ref)
                            }
                        }
                    }
                }
            }
            // This card is also where a placed resident goes to come off an
            // edge — dragging it here and dropping is the only way left to
            // reach `dock.dock(_:to: nil)` now that the editors only point at
            // this screen instead of writing to the store themselves.
            .dropDestination(for: EdgeResidentDrag.self) { drags, _ in
                guard let dragged = drags.first else { return false }
                dock.dock(dragged.id, to: nil)
                return true
            }
        }
    }

    private func unplacedRow(_ item: DockItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: item.icon.image(pointSize: 15))
                    .renderingMode(.template)
                    .foregroundStyle(FlowTheme.inkSecondary)
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                DockPlacementPicker(store: dock, itemID: item.id, unplacedLabel: unplacedLabel(for: item))
            }
            if let sentence = consentSentence(for: item) {
                Text(sentence)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

    /// Uppercase, kerned section label shared by every card on this page —
    /// including the two `extension EdgesSectionContent` blocks in
    /// `EdgesSection+PanelPlacement.swift` and `EdgesSection+FolderHub.swift`,
    /// which is the one reason this is `internal` rather than `private` like
    /// everything else declared in this file.
    func cardHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FlowTheme.inkSecondary)
            .textCase(.uppercase)
            .kerning(0.6)
    }
}

extension EdgesSection {
    /// Every id the "not on an edge" list will ever consider offering a row
    /// and a picker for — exactly the resident set the three edge cards
    /// already draw from (`DockCatalog.knownIDs`), never the wider
    /// `DockCatalog.placeableIDs`. Exposed (rather than kept as a private
    /// detail of `EdgesSectionContent`) so `DockPlacementParityTests` can
    /// hold this against the live catalog directly: a regression back to
    /// `placeableIDs` would offer a picker for something that, once placed,
    /// draws nothing anywhere — see `unplaced`'s doc comment above.
    static func offeredIDs(host: any SettingsHost) -> Set<String> {
        DockCatalog.knownIDs(host: host)
    }

    /// The one built-in dock resident with no `RingActionID` to name it —
    /// the folder hub (see `DockCatalog.builtIns`'s doc comment on why it has
    /// none). Moved here from `SettingsSection` in Task 3 along with the
    /// picker itself: `EdgesSectionContent.consentSentence(for:)` uses it to
    /// pick the folder hub's own wording apart from a `.surface` gizmo's,
    /// since DESIGN.md §11 is explicit the two must not share one sentence.
    /// `DockPlacementParityTests` still holds this, together with
    /// `dockableBuiltIns` mapped to ring-action ids, against every id
    /// `DockCatalog.builtIns(host:)` actually returns — a future resident of
    /// this same ring-slot-less kind joins it here, not a new constant.
    static let residentWithoutARingSlot = ToolRef.folderHub.storageID

    /// Where a drag onto a resident row lands, pulled out of the view so a
    /// test can drive it without rendering one.
    ///
    /// `DockStore.move`'s `index` names a position in the *raw*
    /// `placement[edge]` array — what `dock.items(on:)` returns — and that is
    /// not the same array a card renders. `edgeCard` only draws ids that
    /// resolve to a resident `DockItem`; a built-in like Explain can be
    /// docked (its picker lives in `EdgesSection+PanelPlacement.swift` now)
    /// with nothing to show while idle, so it sits in the raw list without a
    /// row. Indexing into the rendered list and handing that number to
    /// `move` names the wrong slot whenever such an id sits before the
    /// drop target —
    /// silently, since a bad-but-in-bounds index just lands somewhere else in
    /// the raw list rather than failing. Resolving `targetID`'s own position
    /// in the raw list, fresh at drop time, is what keeps the two in the same
    /// coordinate space no matter what sits between them.
    @MainActor
    static func moveOntoResident(_ droppedID: String, target targetID: String, edge: DockEdge, dock: DockStore) {
        guard let rawIndex = dock.items(on: edge).firstIndex(of: targetID) else { return }
        dock.move(droppedID, to: edge, at: rawIndex)
    }

    /// Where a drag past the last resident row lands — same raw-list rule as
    /// `moveOntoResident`, using the raw count rather than however many rows
    /// this card happens to be rendering.
    @MainActor
    static func moveToEnd(_ droppedID: String, edge: DockEdge, dock: DockStore) {
        dock.move(droppedID, to: edge, at: dock.items(on: edge).count)
    }
}

// MARK: - Drag and drop

/// What a resident row hands a drop target: just its dock id. A dedicated
/// type rather than bare `String` so a stray text drag from another app can't
/// land here and read as though it named a real one.
private struct EdgeResidentDrag: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .gizmateEdgeResident)
    }
}

private extension UTType {
    static let gizmateEdgeResident = UTType(exportedAs: "com.nugumi.app.edge-resident")
}

/// One draggable, droppable resident row. Both directions live on the same
/// view: dragging it picks it up, dropping something else onto it reports
/// this row's own id as the drop target — see `EdgesSection.moveOntoResident`.
private struct EdgeResidentRow: View {
    let item: DockItem
    let onDropped: (String) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FlowTheme.inkTertiary)
            Image(nsImage: item.icon.image(pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 18)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isTargeted ? FlowTheme.accentSoft : Color.clear)
        )
        .contentShape(Rectangle())
        .draggable(EdgeResidentDrag(id: item.id))
        .dropDestination(for: EdgeResidentDrag.self) { drags, _ in
            guard let dragged = drags.first, dragged.id != item.id else { return false }
            onDropped(dragged.id)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// The one drop target after the last row in a card — without it there is no
/// way to drag a resident to the end of a list that already has one.
private struct EdgeAppendDropZone: View {
    let onDropped: (String) -> Void

    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted ? FlowTheme.accentSoft : Color.clear)
            .frame(height: isTargeted ? 20 : 8)
            .contentShape(Rectangle())
            .dropDestination(for: EdgeResidentDrag.self) { drags, _ in
                guard let dragged = drags.first else { return false }
                onDropped(dragged.id)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
