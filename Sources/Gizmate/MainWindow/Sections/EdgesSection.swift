import SwiftUI
import UniformTypeIdentifiers

/// One card per screen edge, each listing its residents in tab order, plus
/// every other resident that currently sits on none of them. Deliberately
/// "resident", not the wider "placeable" — see `unplaced`'s doc comment.
///
/// This is a *view* onto `DockStore`, not a new owner of it — placement is
/// still written from `BuiltInEditor`, `ToolEditor` and `SettingsSection`'s
/// Files card, exactly as it is today. This screen only answers the question
/// none of those three can: what is on my right edge, and in what order.
/// Task 3 moves the writing here too and retires those three controls.
struct EdgesSection: View {
    @EnvironmentObject var bridge: GizmateSettingsBridge

    var body: some View {
        // `host` is only nil for the instant between the window opening and
        // `GizmateApp` finishing its own setup — every other section that
        // needs it (`SettingsSection`'s Files card, both editors) assumes the
        // same thing and would show nothing rather than a picker either.
        if let host = bridge.host {
            EdgesSectionContent(dock: bridge.dock, tools: bridge.tools, overrides: bridge.builtInOverrides, host: host)
        }
    }
}

/// Split from `EdgesSection` so the three stores it reads can be
/// `@ObservedObject` — `GizmateSettingsBridge` holds them but never forwards
/// their own publishers, the same reason `NotesGrid` and `DockPlacementPicker`
/// take their store as a parameter instead of reading it off the bridge.
private struct EdgesSectionContent: View {
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
    /// live catalog directly.
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

    var body: some View {
        DetailContainer(
            "Edges",
            subtitle: "What waits on a screen edge, and in what order."
        ) {
            PageBanner(
                title: "One list per side",
                message: "Note, Files, and any gizmo that keeps something on screen can sit on the "
                    + "top, left or right edge, revealed when the pointer gets close. Drag a row to "
                    + "reorder it, or drop it on another edge.",
                symbol: "rectangle.lefthalf.inset.filled",
                dismissKey: "edgesBannerDismissed"
            )
            ForEach(DockEdge.allCases, id: \.self) { edge in
                edgeCard(edge)
            }
            unplacedCard
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
                // to drop onto, so the whole card stands in for one.
                .dropDestination(for: EdgeResidentDrag.self) { drags, _ in
                    guard let dragged = drags.first else { return false }
                    dock.move(dragged.id, to: edge, at: 0)
                    return true
                }
            } else {
                SubCard {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider().background(FlowTheme.hairline) }
                            EdgeResidentRow(
                                item: item,
                                onDropped: { droppedID in move(droppedID, to: edge, at: index) }
                            )
                        }
                        // A trailing drop target the size of a row's padding —
                        // without it, nothing lets a drag land after the last
                        // resident short of dropping past the card entirely.
                        EdgeAppendDropZone { droppedID in move(droppedID, to: edge, at: items.count) }
                    }
                }
            }
        }
    }

    /// `DockStore.move`'s `index` already names the id's final slot — the row
    /// or drop zone reports its own *current* displayed index, and passing
    /// that straight through lands the drag adjacent to wherever it was
    /// dropped whether the id is arriving from another edge or reordering in
    /// place. See `DockStoreTests.testMovingAnItemForwardWithinItsOwnEdgeLandsWhereAsked`.
    private func move(_ id: String, to edge: DockEdge, at index: Int) {
        dock.move(id, to: edge, at: index)
    }

    // MARK: - Unplaced

    private var unplacedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeading("Not on an edge")
            let rows = unplaced
            if rows.isEmpty {
                SubCard {
                    Text("Everything placeable is already on an edge.")
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
    }

    private func unplacedRow(_ item: DockItem) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon.image(pointSize: 15))
                .renderingMode(.template)
                .foregroundStyle(FlowTheme.inkSecondary)
                .frame(width: 18)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.ink)
            Spacer(minLength: 12)
            DockPlacementPicker(store: dock, itemID: item.id, unplacedLabel: unplacedLabel(for: item))
        }
        .padding(.vertical, 9)
    }

    private func cardHeading(_ text: String) -> some View {
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
/// this row's own index as the target — see `EdgesSectionContent.move`.
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
